const form = document.querySelector('#connect');
const status = document.querySelector('#status');
const speakers = document.querySelector('#speakers');
const channelControl = document.querySelector('#channel-control');
const channelSelect = document.querySelector('#channel');
const connectionToggle = document.querySelector('#connection-toggle');
let socket;
let peer;
let heartbeat;
let statsTimer;
let microphoneStream;
let renegotiationRequested = false;
let renegotiationInProgress = false;
let connectionOptions;
let reconnectTimer;
let reconnectAttempts = 0;
let reconnectEnabled = false;
let connectionActive = false;
let wakeLock;
const speakerInfoByMid = new Map();
const currentChannelSessions = new Set();
const speakerAudio = new Set();
let playbackResumeRunning = false;
const connectionFragmentFields = [
  { parameter: 'host', input: form.elements.namedItem('server') },
  { parameter: 'port', input: form.elements.namedItem('port') },
  { parameter: 'user', input: form.elements.namedItem('username') },
  { parameter: 'password', input: form.elements.namedItem('password') },
];

function loadConnectionFragment() {
  const parameters = new URLSearchParams(location.hash.slice(1));
  for (const { parameter, input } of connectionFragmentFields) {
    if (parameters.has(parameter)) input.value = parameters.get(parameter);
  }
}

function saveConnectionFragment() {
  const parameters = new URLSearchParams();
  for (const { parameter, input } of connectionFragmentFields) parameters.set(parameter, input.value);
  history.replaceState(history.state, '', `${location.pathname}${location.search}#${parameters}`);
}

for (const { input } of connectionFragmentFields) input.addEventListener('blur', saveConnectionFragment);
loadConnectionFragment();

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
    const outbound = [];
    reports.forEach((report) => {
      if (report.type === 'codec') codecs.set(report.id, report);
      else if (report.type === 'transport') transports.set(report.id, report);
      else if (report.type === 'inbound-rtp' && (report.kind === 'audio' || report.mediaType === 'audio')) inbound.push(report);
      else if (report.type === 'outbound-rtp' && (report.kind === 'audio' || report.mediaType === 'audio')) outbound.push(report);
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
          jitterBufferMeanDelay: report.jitterBufferEmittedCount > 0 ? metric(report.jitterBufferDelay / report.jitterBufferEmittedCount) : null,
          jitterBufferTargetDelay: metric(report.jitterBufferTargetDelay),
          concealedSamples: report.concealedSamples ?? null,
          concealmentEvents: report.concealmentEvents ?? null,
          codec: codec?.mimeType ?? null,
          clockRate: codec?.clockRate ?? null,
        };
      }),
      outbound: outbound.map((report) => ({
        ssrc: report.ssrc,
        packets: report.packetsSent,
        bytes: report.bytesSent,
        codec: codecs.get(report.codecId)?.mimeType ?? null,
      })),
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

// iOS Safari suspends the page's audio session during a system mic
// interruption (Siri, an incoming call, backgrounding) and pauses every media
// element without ever resuming it. Autoplay here is granted by the active
// getUserMedia capture, which is exactly what the interruption takes away, so
// an element created or paused during one stays silent while its RTP keeps
// arriving. Nothing else in this page calls play(), so this is the only path
// back to audible.
async function resumeSpeakerPlayback(reason) {
  if (playbackResumeRunning) return;
  playbackResumeRunning = true;
  try {
    // The audio session is restored asynchronously after the interruption
    // ends, so a single attempt often lands too early.
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const paused = [...speakerAudio].filter((audio) => audio.paused);
      if (!paused.length) return;
      browserLog('resuming speaker playback', { reason, attempt, paused: paused.length });
      for (const audio of paused) {
        try {
          await audio.play();
        } catch (error) {
          browserLog('speaker playback resume failed', {
            reason,
            attempt,
            session: audio.dataset.session || null,
            message: String(error),
            name: error.name,
          });
        }
      }
      if (![...speakerAudio].some((audio) => audio.paused)) return;
      await new Promise((resolve) => window.setTimeout(resolve, 250));
    }
  } finally {
    playbackResumeRunning = false;
  }
}

function removeSpeakerArticle(article) {
  for (const audio of article.querySelectorAll('audio')) speakerAudio.delete(audio);
  article.remove();
}

async function acquireWakeLock() {
  if (!navigator.wakeLock?.request || wakeLock) return;
  browserLog('screen wake lock requesting', { visibilityState: document.visibilityState, connectionActive, hasGesture: navigator.userActivation?.isActive });
  try {
    wakeLock = await navigator.wakeLock.request('screen');
    wakeLock.addEventListener('release', () => {
      browserLog('screen wake lock released by system');
      wakeLock = undefined;
      void requestWakeLock();
    });
    browserLog('screen wake lock enabled');
  } catch (error) {
    browserLog('screen wake lock unavailable', { message: String(error), name: error.name });
  }
}
async function requestWakeLock() {
  if (!connectionActive) {
    browserLog('screen wake lock skipped: not connected');
    return;
  }
  if (document.visibilityState !== 'visible') {
    browserLog('screen wake lock skipped: not visible', { visibilityState: document.visibilityState });
    return;
  }
  await acquireWakeLock();
}
async function releaseWakeLock() {
  if (!wakeLock) return;
  browserLog('screen wake lock releasing');
  const lock = wakeLock;
  wakeLock = undefined;
  await lock.release();
}
document.addEventListener('visibilitychange', () => {
  browserLog('visibility change', { visibilityState: document.visibilityState });
  if (document.visibilityState === 'visible') {
    void requestWakeLock();
    void resumeSpeakerPlayback('visibility change');
  }
});
window.addEventListener('focus', () => {
  void requestWakeLock();
  void resumeSpeakerPlayback('window focus');
});
window.addEventListener('pagehide', () => { void releaseWakeLock(); });
function setConnectionActive(active) {
  connectionActive = active;
  connectionToggle.textContent = active ? 'Disconnect' : 'Connect';
}
function signal(message) { socket.send(JSON.stringify(message)); }
function updateChannels({ current_channel: currentChannel, channels, users }) {
  const selected = String(currentChannel ?? '');
  channelSelect.replaceChildren();
  for (const channel of (channels || []).sort((left, right) => left.name.localeCompare(right.name))) {
    const option = document.createElement('option');
    option.value = String(channel.id);
    option.textContent = channel.name;
    option.selected = option.value === selected;
    channelSelect.append(option);
  }
  channelControl.hidden = channelSelect.options.length === 0;
  channelSelect.disabled = !connectionActive || !selected;
  currentChannelSessions.clear();
  for (const user of users || []) currentChannelSessions.add(String(user.session));
  const trackedSessions = new Set([...speakerInfoByMid.values()].map((speaker) => String(speaker.session)));
  for (const article of speakers.querySelectorAll('article')) {
    // Never drop an element the gateway still has a track for. The roster is
    // empty in every channel_state sent before ServerSync (current_channel is
    // null until then), and an article whose mid was missing from the answer
    // has no session at all — removing either one silences a live stream with
    // no way to recreate it, since ontrack will not fire again.
    const session = article.dataset.session;
    if (!session || currentChannelSessions.has(session) || trackedSessions.has(session)) continue;
    removeSpeakerArticle(article);
  }
}
channelSelect.addEventListener('change', () => {
  if (connectionActive && channelSelect.value) signal({ type: 'switch_channel', channel: Number(channelSelect.value) });
});
function browserLog(event, details = {}) {
  details.time = Date.now();
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

async function captureMicrophone(restart = false) {
  if (microphoneStream?.active && !restart) return;
  if (restart) stopMicrophone();
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('Microphone capture is not supported by this browser');
  // This is intentionally requested inside the Connect tap. While Safari is
  // capturing a MediaStream, it permits the remote WebRTC audio to autoplay.
  microphoneStream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    video: false,
  });
  const audioTrack = microphoneStream.getAudioTracks()[0];
  if (audioTrack) {
    audioTrack.onmute = () => {
      audioTrack.enabled = false;
      browserLog('microphone muted by system', { muted: audioTrack.muted, enabled: audioTrack.enabled, readyState: audioTrack.readyState });
    };
    audioTrack.onunmute = () => {
      audioTrack.enabled = true;
      browserLog('microphone unmuted by system', { muted: audioTrack.muted, enabled: audioTrack.enabled, readyState: audioTrack.readyState });
      // iOS may release the wake lock during a system audio interruption;
      // try to re-acquire when the mic is restored. The same interruption
      // paused every speaker element, so restart those too.
      void requestWakeLock();
      void resumeSpeakerPlayback('microphone unmuted');
    };
  }
  browserLog('microphone capture enabled');
}

function stopMicrophone() {
  microphoneStream?.getTracks().forEach((track) => track.stop());
  microphoneStream = undefined;
}

async function sendOffer() {
  const offer = await peer.createOffer({ offerToReceiveAudio: true });
  await peer.setLocalDescription(offer);
  signal({ type: 'offer', sdp: offer.sdp });
}

async function attemptRenegotiation() {
  if (!renegotiationRequested || renegotiationInProgress || !peer || peer.signalingState !== 'stable') return;
  renegotiationRequested = false;
  renegotiationInProgress = true;
  try {
    // The gateway has learned about another Mumble speaker. Add one offered
    // receive-only audio section so it can answer with that speaker's track.
    peer.addTransceiver('audio', { direction: 'recvonly' });
    await sendOffer();
  } catch (error) {
    renegotiationRequested = true;
    browserError('WebRTC renegotiation failed', { message: String(error) });
  } finally {
    renegotiationInProgress = false;
  }
}

async function makeOffer(speakerCount = 1) {
  renegotiationRequested = false;
  renegotiationInProgress = false;
  // Every track belongs to the PeerConnection being replaced, so drop the old
  // elements rather than leaving dead ones for updateChannels to reap.
  speakers.replaceChildren();
  speakerAudio.clear();
  const currentPeer = new RTCPeerConnection({ iceServers: [] });
  peer = currentPeer;
  // Use the first speaker m= section in both directions. libdatachannel only
  // answers the offered sections it can pair with a local track; a separate
  // microphone section would therefore be rejected as inactive. The two
  // directions still retain independent RTP streams and Opus packets.
  peer.addTransceiver(microphoneStream.getAudioTracks()[0], { direction: 'sendrecv' });
  for (let index = 1; index < Math.max(1, speakerCount); index += 1) {
    peer.addTransceiver('audio', { direction: 'recvonly' });
  }
  currentPeer.onicecandidate = ({ candidate }) => {
    if (peer !== currentPeer) return;
    if (candidate) {
      browserLog('local ICE candidate', { mid: candidate.sdpMid, type: candidate.type, protocol: candidate.protocol });
      signal({ type: 'candidate', candidate: candidate.candidate, mid: candidate.sdpMid });
    } else {
      browserLog('local ICE gathering complete');
    }
  };
  currentPeer.onconnectionstatechange = () => {
    if (peer !== currentPeer) return;
    browserLog('peer connection state', { state: currentPeer.connectionState });
    if (currentPeer.connectionState === 'connected') {
      startMediaStats();
    } else if (currentPeer.connectionState === 'disconnected' || currentPeer.connectionState === 'failed') {
      socket?.close();
    }
  };
  currentPeer.oniceconnectionstatechange = () => {
    if (peer !== currentPeer) return;
    const details = { state: currentPeer.iceConnectionState };
    if (currentPeer.iceConnectionState === 'failed') {
      browserError('ICE failed', details);
      socket?.close();
    } else browserLog('ICE connection state', details);
  };
  currentPeer.onicecandidateerror = ({ url, errorCode, errorText }) => {
    if (peer === currentPeer) browserError('ICE candidate error', { url, errorCode, errorText });
  };
  currentPeer.onsignalingstatechange = () => {
    if (peer !== currentPeer) return;
    browserLog('signalling state', { state: currentPeer.signalingState });
    void attemptRenegotiation();
  };
  currentPeer.ontrack = ({ track, streams, transceiver }) => {
    if (peer !== currentPeer) return;
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
//    const volumeLabel = document.createElement('label');
//    volumeLabel.textContent = 'Volume';
    const volume = document.createElement('input');
    volume.type = 'range';
    volume.min = '0';
    volume.max = '100';
    volume.step = '1';
    volume.value = '100';
    volume.setAttribute('aria-label', `Volume`);
//Volume for ${label}`);
    volume.addEventListener('change', () => {
      const percent = Number(volume.value);
      audio.volume = Number.isFinite(percent) ? Math.min(100, Math.max(0, percent)) / 100 : 1;
    });
//    volumeLabel.append(volume);
    audio.onplaying = () => browserLog('speaker audio playing', { track: track.id, session: speaker?.session ?? null, readyState: audio.readyState, currentTime: metric(audio.currentTime) });
    audio.onwaiting = () => {
      browserLog('speaker audio waiting', { track: track.id, session: speaker?.session ?? null, readyState: audio.readyState, currentTime: metric(audio.currentTime) });
      void resumeSpeakerPlayback('speaker audio waiting');
    };
    audio.onstalled = () => {
      browserLog('speaker audio stalled', { track: track.id, session: speaker?.session ?? null });
      void resumeSpeakerPlayback('speaker audio stalled');
    };
    audio.onerror = () => browserLog('speaker audio error', { track: track.id, session: speaker?.session ?? null, error: audio.error?.message });
    track.onmute = () => browserLog('remote track muted', { id: track.id, session: speaker?.session ?? null });
    track.onunmute = () => browserLog('remote track unmuted', { id: track.id, session: speaker?.session ?? null });
    container.dataset.session = speaker?.session ?? '';
    container.append(heading, volume, audio);
    speakers.append(container);
    speakerAudio.add(audio);
    // A track that arrives while the audio session is interrupted cannot
    // autoplay, so ask for playback explicitly rather than trusting the
    // autoplay attribute.
    void resumeSpeakerPlayback('remote track added');
    track.onended = () => { browserLog('remote track ended', { id: track.id, session: speaker?.session ?? null }); removeSpeakerArticle(container); };
  };
  await sendOffer();
}

function scheduleReconnect() {
  if (!reconnectEnabled || reconnectTimer) return;
  const delay = Math.min(1_000 * (2 ** reconnectAttempts), 30_000);
  reconnectAttempts += 1;
  setStatus(`Disconnected; reconnecting in ${Math.round(delay / 1_000)} seconds…`);
  reconnectTimer = window.setTimeout(async () => {
    reconnectTimer = undefined;
    try {
      // Reacquire instead of reusing the old track: iOS Safari can leave a
      // track alive but no longer transmit it after its PeerConnection drops.
      await captureMicrophone(true);
      connectSignalling();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      browserError('microphone recapture failed', { message });
      scheduleReconnect();
    }
  }, delay);
}

function connectSignalling() {
  const currentSocket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/wumble/ws`);
  socket = currentSocket;
  currentSocket.onopen = () => {
    if (socket !== currentSocket) return;
    setStatus('Connecting to Mumble…');
    signal({ type: 'connect', options: connectionOptions });
    browserLog('signalling socket opened');
    // Keep reverse proxies from expiring an otherwise idle signalling socket.
    heartbeat = window.setInterval(() => signal({ type: 'ping' }), 20_000);
  };
  currentSocket.onmessage = async ({ data }) => {
    if (socket !== currentSocket) return;
    const message = JSON.parse(data);
    browserLog('received signalling message', { type: message.type });
    if (message.type === 'pong') {
      return;
    } else if (message.type === 'connected') {
      reconnectAttempts = 0;
      browserLog('creating offer', { speakers: message.speakers });
      await makeOffer(message.speakers);
    } else if (message.type === 'channel_state') {
      updateChannels(message);
    } else if (message.type === 'restart_webrtc') {
      browserLog('restarting WebRTC for channel change', { speakers: message.speakers });
      peer?.close();
      peer = undefined;
      speakerInfoByMid.clear();
      await makeOffer(message.speakers);
    } else if (message.type === 'answer') {
      speakerInfoByMid.clear();
      for (const speaker of message.speakers || []) speakerInfoByMid.set(speaker.mid, speaker);
      await peer.setRemoteDescription({ type: message.description_type, sdp: message.sdp });
      browserLog('accepted WebRTC answer', { sdpBytes: message.sdp.length });
      setStatus('Connected');
      setConnectionActive(true);
      channelSelect.disabled = false;
      void requestWakeLock();
      await attemptRenegotiation();
    } else if (message.type === 'renegotiate') {
      browserLog('gateway requested WebRTC renegotiation');
      renegotiationRequested = true;
      await attemptRenegotiation();
    } else if (message.type === 'candidate') {
      await peer.addIceCandidate({ candidate: message.candidate, sdpMid: message.mid });
    } else if (message.type === 'mumble_disconnected') {
      browserLog('Mumble connection dropped', { message: message.message });
      currentSocket.close();
    } else if (message.type === 'udp_unavailable' || message.type === 'error') {
      reconnectEnabled = false;
      setStatus(`Error: ${message.message}`);
      if (message.type === 'udp_unavailable') window.alert(message.message);
      currentSocket.close();
    }
  };
  currentSocket.onerror = () => {
    if (socket === currentSocket) browserLog('signalling WebSocket error');
  };
  currentSocket.onclose = ({ code, reason }) => {
    if (socket !== currentSocket) return;
    window.clearInterval(heartbeat);
    window.clearInterval(statsTimer);
    peer?.close();
    peer = undefined;
    console.info(`Wumble signalling WebSocket closed (${code}: ${reason || 'no reason'})`);
    setConnectionActive(false);
    channelSelect.disabled = true;
    void releaseWakeLock();
    if (reconnectEnabled) {
      scheduleReconnect();
    } else {
      stopMicrophone();
      setStatus(`Disconnected (${code})`);
    }
  };
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (connectionActive) {
    reconnectEnabled = false;
    const activeSocket = socket;
    socket = undefined;
    activeSocket?.close();
    peer?.close();
    peer = undefined;
    window.clearInterval(heartbeat);
    window.clearInterval(statsTimer);
    stopMicrophone();
    setConnectionActive(false);
    channelSelect.disabled = true;
    void releaseWakeLock();
    setStatus('Disconnected');
    return;
  }
  window.clearTimeout(reconnectTimer);
  reconnectTimer = undefined;
  reconnectEnabled = false;
  const previousSocket = socket;
  socket = undefined;
  previousSocket?.close();
  peer?.close();
  peer = undefined;
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
  connectionOptions = {
    server: values.get('server'),
    port: Number(values.get('port')),
    username: values.get('username'),
    password: values.get('password'),
  };
  reconnectAttempts = 0;
  reconnectEnabled = true;
  // Acquire the Screen Wake Lock while we still have the user gesture from
  // the Connect button press. Safari on iOS requires transient activation
  // for navigator.wakeLock.request('screen').
  void acquireWakeLock();
  connectSignalling();
});
