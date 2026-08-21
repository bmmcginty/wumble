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
// Element -> the remote track it plays. The track is kept because reattaching
// after an interruption has to build a new MediaStream around the same track.
const speakerAudio = new Map();
let playbackResumeRunning = false;
let audioProbe;
let audioRecoveryRunning = false;
let audioRecoveryNeeded = false;
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
      const paused = [...speakerAudio.keys()].filter((audio) => audio.paused);
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
      if (![...speakerAudio.keys()].some((audio) => audio.paused)) return;
      await new Promise((resolve) => window.setTimeout(resolve, 250));
    }
  } finally {
    playbackResumeRunning = false;
  }
}

// Pausing and playing is only a repair for an element Safari itself stopped.
// After a Siri interruption the elements come back reporting that they are
// playing -- currentTime keeps advancing and inbound-rtp keeps reporting audio
// energy -- while nothing reaches the speaker, and no element event fires.
// Pointing each element at a fresh MediaStream over the same track is the only
// way from script to make Safari build a new renderer for it.
async function reattachSpeakerAudio(reason) {
  if (!speakerAudio.size) return;
  browserLog('reattaching speaker audio', { reason, speakers: speakerAudio.size });
  for (const [audio, track] of speakerAudio) {
    try {
      audio.srcObject = null;
      audio.srcObject = new MediaStream([track]);
      await audio.play();
    } catch (error) {
      browserLog('speaker reattach failed', {
        reason,
        session: audio.dataset.session || null,
        message: String(error),
        name: error.name,
      });
    }
  }
}

// Rebuild what the interruption tore down, in dependency order: the audio
// session first, then the elements that render into it. Resuming the context
// alone was tried and is not enough -- it returns to 'running' and the speakers
// stay silent -- so the context state is a reliable detector of the
// interruption, and the reattach is the repair.
async function recoverAudio(reason) {
  if (audioRecoveryRunning || !connectionActive) return;
  audioRecoveryRunning = true;
  try {
    browserLog('audio recovery starting', {
      reason,
      visibility: document.visibilityState,
      audioContext: audioProbe?.state ?? null,
      speakers: speakerAudio.size,
    });
    await resumeAudioProbe(reason);
    await reattachSpeakerAudio(reason);
    await resumeSpeakerPlayback(reason);
    browserLog('audio recovery finished', { reason, audioContext: audioProbe?.state ?? null });
  } catch (error) {
    browserError('audio recovery failed', { reason, message: String(error), name: error.name });
  } finally {
    audioRecoveryRunning = false;
  }
}

// The interruption ends in several steps that arrive in any order: the page
// becomes visible again, the capture unmutes, and the audio context leaves
// 'interrupted'. Recovering needs all of them, so whichever lands last runs it.
// The context guard is not just bookkeeping: resume() while iOS still holds
// the session is the call that fails.
function maybeRecoverAudio(reason) {
  if (!audioRecoveryNeeded || !connectionActive) return;
  if (document.visibilityState !== 'visible') return;
  if (microphoneStream?.getAudioTracks()[0]?.muted) return;
  if (audioProbe?.state === 'interrupted') return;
  audioRecoveryNeeded = false;
  void recoverAudio(reason);
}

// Safari parks every audio context of an interrupted page in the non-standard
// 'interrupted' state and leaves it there, which is the one direct read the
// page gets on its own audio session. Nothing is connected to this context:
// routing speaker audio through Web Audio was tried and reverted, and doing it
// again here would put the reverted path back on the hot audio route.
function startAudioProbe() {
  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  if (audioProbe || !AudioContextClass) return;
  audioProbe = new AudioContextClass();
  audioProbe.onstatechange = () => {
    const state = audioProbe?.state ?? null;
    browserLog('audio context state', { state });
    // 'interrupted' is a first-hand report that iOS took the session away,
    // which a system capture mute only implies. Arm on it as well so an
    // interruption that never mutes the capture still gets recovered.
    if (state === 'interrupted') audioRecoveryNeeded = true;
    else maybeRecoverAudio('audio context state');
  };
  browserLog('audio context created', { state: audioProbe.state, sampleRate: audioProbe.sampleRate });
}

async function resumeAudioProbe(reason) {
  if (!audioProbe || audioProbe.state === 'running') return;
  browserLog('audio context resuming', { reason, state: audioProbe.state });
  try {
    await audioProbe.resume();
    browserLog('audio context resumed', { reason, state: audioProbe.state });
  } catch (error) {
    browserLog('audio context resume failed', { reason, state: audioProbe.state, message: String(error), name: error.name });
  }
}

function stopAudioProbe() {
  if (!audioProbe) return;
  const context = audioProbe;
  audioProbe = undefined;
  context.onstatechange = null;
  void context.close().catch(() => {});
}

function removeSpeakerArticle(article) {
  for (const audio of article.querySelectorAll('audio')) speakerAudio.delete(audio);
  article.remove();
}

function clearSpeakerArticles() {
  speakers.replaceChildren();
  speakerAudio.clear();
  speakerInfoByMid.clear();
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
    maybeRecoverAudio('visibility change');
  }
});
window.addEventListener('focus', () => {
  void requestWakeLock();
  void resumeSpeakerPlayback('window focus');
  maybeRecoverAudio('window focus');
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
  const namesBySession = new Map();
  for (const user of users || []) {
    const session = String(user.session);
    currentChannelSessions.add(session);
    namesBySession.set(session, user.name);
  }
  // Before ServerSync current_channel is null and the roster is necessarily
  // empty. Do not mistake that initial partial state for every user leaving.
  if (currentChannel == null) return;
  for (const article of speakers.querySelectorAll('article')) {
    const session = article.dataset.session;
    // An answer without a mapping cannot be reconciled to the Mumble roster;
    // retain it until its track ends or this PeerConnection is cleared.
    if (!session) continue;
    if (!currentChannelSessions.has(session)) {
      browserLog('removing departed speaker', { session, mid: article.dataset.mid || null });
      removeSpeakerArticle(article);
      continue;
    }
    const name = namesBySession.get(session);
    if (name) {
      const label = `${name} (session ${session})`;
      article.querySelector('h2').textContent = label;
      article.querySelector('audio').title = label;
    }
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
      // A system mute is the only unambiguous notice the page gets that iOS
      // took the audio session away, so it is what arms the recovery. Page
      // visibility alone is not: a desktop tab switch would then tear down and
      // rebuild every speaker element for nothing.
      audioRecoveryNeeded = true;
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
      maybeRecoverAudio('microphone unmuted');
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
  clearSpeakerArticles();
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
    // A renegotiation should retain the same receiver, but Safari can emit a
    // duplicate ontrack for an existing m= section. Keep one article per mid.
    for (const article of speakers.querySelectorAll('article')) {
      if (article.dataset.mid === (transceiver?.mid ?? '')) removeSpeakerArticle(article);
    }
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
    container.dataset.mid = transceiver?.mid ?? '';
    container.append(heading, volume, audio);
    speakers.append(container);
    speakerAudio.set(audio, track);
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
    clearSpeakerArticles();
    currentChannelSessions.clear();
    console.info(`Wumble signalling WebSocket closed (${code}: ${reason || 'no reason'})`);
    setConnectionActive(false);
    channelSelect.disabled = true;
    void releaseWakeLock();
    if (reconnectEnabled) {
      scheduleReconnect();
    } else {
      stopMicrophone();
      stopAudioProbe();
      audioRecoveryNeeded = false;
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
    clearSpeakerArticles();
    currentChannelSessions.clear();
    window.clearInterval(heartbeat);
    window.clearInterval(statsTimer);
    stopMicrophone();
    stopAudioProbe();
    audioRecoveryNeeded = false;
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
  // Same reason: a context created outside a gesture starts suspended, which
  // would be indistinguishable from the interruption it exists to report.
  startAudioProbe();
  connectSignalling();
});
