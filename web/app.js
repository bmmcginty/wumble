const form = document.querySelector('#connect');
const status = document.querySelector('#status');
const speakers = document.querySelector('#speakers');
let socket;
let peer;
let heartbeat;
let statsTimer;
let microphoneStream;
const speakerInfoByMid = new Map();

function metric(value) {
  return typeof value === 'number' ? Math.round(value * 1000) / 1000 : null;
}

async function logMediaStats() {
  if (!peer || peer.connectionState === 'closed') return;
  try {
    const reports = await peer.getStats();
    const codecs = new Map();
    const transports = new Map();
    const inbound = [];
    reports.forEach((report) => {
      if (report.type === 'codec') codecs.set(report.id, report);
      else if (report.type === 'transport') transports.set(report.id, report);
      else if (report.type === 'inbound-rtp' && (report.kind === 'audio' || report.mediaType === 'audio')) inbound.push(report);
    });
    browserLog('WebRTC audio stats', {
      connection: peer.connectionState,
      ice: peer.iceConnectionState,
      inbound: inbound.map((report) => {
        const codec = codecs.get(report.codecId);
        return {
          ssrc: report.ssrc,
          packets: report.packetsReceived,
          bytes: report.bytesReceived,
          lost: report.packetsLost,
          jitter: metric(report.jitter),
          audioLevel: metric(report.audioLevel),
          totalAudioEnergy: metric(report.totalAudioEnergy),
          totalSamplesDuration: metric(report.totalSamplesDuration),
          jitterBufferDelay: metric(report.jitterBufferDelay),
          jitterBufferEmittedCount: report.jitterBufferEmittedCount ?? null,
          concealedSamples: report.concealedSamples ?? null,
          concealmentEvents: report.concealmentEvents ?? null,
          codec: codec?.mimeType ?? null,
          clockRate: codec?.clockRate ?? null,
        };
      }),
      transports: [...transports.values()].map((report) => ({
        state: report.dtlsState,
        selectedCandidatePairId: report.selectedCandidatePairId ?? null,
        bytesReceived: report.bytesReceived,
        bytesSent: report.bytesSent,
      })),
    });
  } catch (error) {
    browserError('WebRTC stats failed', { message: String(error) });
  }
}

function startMediaStats() {
  window.clearInterval(statsTimer);
  logMediaStats();
  statsTimer = window.setInterval(logMediaStats, 5_000);
}

function setStatus(text) { status.textContent = text; }
function signal(message) { socket.send(JSON.stringify(message)); }
function browserLog(event, details = {}) {
  console.info(`Wumble: ${event}`, details);
  if (socket?.readyState === WebSocket.OPEN) signal({ type: 'log', event, details });
}
const nativeConsoleError = console.error.bind(console);
console.error = (...values) => {
  nativeConsoleError(...values);
  const message = values.map((value) => value instanceof Error ? (value.stack || value.message) : String(value)).join(' ');
  browserLog('console.error', { message });
};
function browserError(event, details = {}) {
  // The console.error wrapper forwards this to the gateway log stream.
  console.error(`Wumble: ${event}`, details);
}
window.addEventListener('error', ({ message, filename, lineno, colno }) => {
  browserError('window error', { message, filename, lineno, colno });
});
window.addEventListener('unhandledrejection', ({ reason }) => {
  browserError('unhandled promise rejection', { reason: String(reason) });
});

async function captureMicrophone() {
  if (microphoneStream?.active) return;
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('Microphone capture is not supported by this browser');
  // This is intentionally requested inside the Connect tap. While Safari is
  // capturing a MediaStream, it permits the remote WebRTC audio to autoplay.
  microphoneStream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    video: false,
  });
  browserLog('microphone capture enabled');
}

function stopMicrophone() {
  microphoneStream?.getTracks().forEach((track) => track.stop());
  microphoneStream = undefined;
}

async function makeOffer(speakerCount = 1) {
  peer = new RTCPeerConnection({ iceServers: [] });
  // The answerer maps one sendonly Mumble speaker track to each of these
  // recvonly media sections; none of the speaker audio is combined.
  for (let index = 0; index < Math.max(1, speakerCount); index += 1) {
    peer.addTransceiver('audio', { direction: 'recvonly' });
  }
  peer.onicecandidate = ({ candidate }) => {
    if (candidate) {
      browserLog('local ICE candidate', { mid: candidate.sdpMid, type: candidate.type, protocol: candidate.protocol });
      signal({ type: 'candidate', candidate: candidate.candidate, mid: candidate.sdpMid });
    } else {
      browserLog('local ICE gathering complete');
    }
  };
  peer.onconnectionstatechange = () => {
    browserLog('peer connection state', { state: peer.connectionState });
    if (peer.connectionState === 'connected') startMediaStats();
  };
  peer.oniceconnectionstatechange = () => {
    const details = { state: peer.iceConnectionState };
    if (peer.iceConnectionState === 'failed') browserError('ICE failed', details);
    else browserLog('ICE connection state', details);
  };
  peer.onicecandidateerror = ({ url, errorCode, errorText }) => {
    browserError('ICE candidate error', { url, errorCode, errorText });
  };
  peer.onsignalingstatechange = () => browserLog('signalling state', { state: peer.signalingState });
  peer.ontrack = ({ track, streams, transceiver }) => {
    const speaker = speakerInfoByMid.get(transceiver?.mid);
    const label = speaker ? `${speaker.name} (session ${speaker.session})` : 'Unknown speaker';
    browserLog('received remote track', { id: track.id, kind: track.kind, streams: streams.length, mid: transceiver?.mid, speaker });
    // Do not combine tracks into one MediaStream. One received track means one
    // Mumble speaker and gets its own audio element and jitter buffer.
    const container = document.createElement('article');
    const heading = document.createElement('h2');
    heading.textContent = label;
    const audio = document.createElement('audio');
    audio.autoplay = true;
    audio.controls = true;
    audio.title = label;
    audio.srcObject = streams[0] || new MediaStream([track]);
    audio.dataset.trackId = track.id;
    audio.dataset.session = speaker?.session ?? '';
    audio.onplaying = () => browserLog('speaker audio playing', { track: track.id, session: speaker?.session ?? null, readyState: audio.readyState, currentTime: metric(audio.currentTime) });
    audio.onwaiting = () => browserLog('speaker audio waiting', { track: track.id, session: speaker?.session ?? null, readyState: audio.readyState, currentTime: metric(audio.currentTime) });
    audio.onstalled = () => browserLog('speaker audio stalled', { track: track.id, session: speaker?.session ?? null });
    audio.onerror = () => browserLog('speaker audio error', { track: track.id, session: speaker?.session ?? null, error: audio.error?.message });
    track.onmute = () => browserLog('remote track muted', { id: track.id, session: speaker?.session ?? null });
    track.onunmute = () => browserLog('remote track unmuted', { id: track.id, session: speaker?.session ?? null });
    container.append(heading, audio);
    speakers.append(container);
    track.onended = () => { browserLog('remote track ended', { id: track.id, session: speaker?.session ?? null }); container.remove(); };
  };
  const offer = await peer.createOffer({ offerToReceiveAudio: true });
  await peer.setLocalDescription(offer);
  signal({ type: 'offer', sdp: offer.sdp });
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  setStatus('Requesting microphone access…');
  try {
    await captureMicrophone();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    setStatus(`Microphone access is required: ${message}`);
    browserError('microphone capture failed', { message });
    return;
  }
  const values = new FormData(form);
  const options = {
    server: values.get('server'),
    port: Number(values.get('port')),
    username: values.get('username'),
    password: values.get('password'),
  };
  socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/wumble/ws`);
  socket.onopen = () => {
    setStatus('Connecting to Mumble…');
    signal({ type: 'connect', options });
    browserLog('signalling socket opened');
    // Keep reverse proxies from expiring an otherwise idle signalling socket.
    heartbeat = window.setInterval(() => signal({ type: 'ping' }), 20_000);
  };
  socket.onmessage = async ({ data }) => {
    const message = JSON.parse(data);
    browserLog('received signalling message', { type: message.type });
    if (message.type === 'pong') {
      return;
    } else if (message.type === 'connected') {
      browserLog('creating offer', { speakers: message.speakers });
      await makeOffer(message.speakers);
    } else if (message.type === 'answer') {
      speakerInfoByMid.clear();
      for (const speaker of message.speakers || []) speakerInfoByMid.set(speaker.mid, speaker);
      await peer.setRemoteDescription({ type: message.description_type, sdp: message.sdp });
      browserLog('accepted WebRTC answer', { sdpBytes: message.sdp.length });
      setStatus('Connected');
    } else if (message.type === 'candidate') {
      await peer.addIceCandidate({ candidate: message.candidate, sdpMid: message.mid });
    } else if (message.type === 'udp_unavailable') {
      setStatus(`Error: ${message.message}`);
      window.alert(message.message);
      socket.close();
    } else if (message.type === 'error') {
      setStatus(`Error: ${message.message}`);
      socket.close();
    }
  };
  socket.onerror = () => browserLog('signalling WebSocket error');
  socket.onclose = ({ code, reason }) => {
    window.clearInterval(heartbeat);
    window.clearInterval(statsTimer);
    stopMicrophone();
    console.info(`Wumble signalling WebSocket closed (${code}: ${reason || 'no reason'})`);
    setStatus(`Disconnected (${code})`);
  };
});
