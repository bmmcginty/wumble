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
let systemMicrophoneMuted = false;
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
// mid -> the remote track ontrack delivered for that m= section. Offered
// sections outnumber speakers (see SPARE_SPEAKER_SECTIONS), so a section can
// receive its track long before the gateway assigns a speaker to it. ontrack
// fires once per section and never again, so the track has to be held here
// until there is a speaker to build an element for.
const remoteTracksByMid = new Map();
const SPARE_SPEAKER_SECTIONS = 6;
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
          await playWithTimeout(audio);
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

// iOS can hand back a play() or resume() promise that never settles while it
// still holds the audio session. Every await on the recovery path goes through
// this, because one unsettling promise used to strand the whole recovery.
const TIMED_OUT = Symbol('timed out');
const PLAY_TIMEOUT_MS = 2_000;
const AUDIO_RESUME_TIMEOUT_MS = 3_000;
function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((resolve) => window.setTimeout(() => resolve(TIMED_OUT), ms)),
  ]);
}

function playWithTimeout(audio) {
  return withTimeout(audio.play(), PLAY_TIMEOUT_MS);
}

// Pausing and playing is only a repair for an element Safari itself stopped.
// After a Siri interruption the elements come back reporting that they are
// playing -- currentTime keeps advancing and inbound-rtp keeps reporting audio
// energy -- while nothing reaches the speaker, and no element event fires.
// Pointing each element at a fresh MediaStream over the same track is the only
// way from script to make Safari build a new renderer for it.
async function reattachSpeakerElement(audio, reason) {
  const track = speakerAudio.get(audio);
  if (!track) return;
  try {
    audio.srcObject = null;
    audio.srcObject = new MediaStream([track]);
    // iOS can return a play() promise that never settles while it still holds
    // the audio session. Awaiting it unbounded would stall the caller's loop
    // and leave every later speaker un-reattached.
    await playWithTimeout(audio);
  } catch (error) {
    browserLog('speaker reattach failed', {
      reason,
      session: audio.dataset.session || null,
      message: String(error),
      name: error.name,
    });
  }
}

async function reattachSpeakerAudio(reason) {
  if (!speakerAudio.size) return;
  browserLog('reattaching speaker audio', { reason, speakers: speakerAudio.size });
  for (const audio of [...speakerAudio.keys()]) await reattachSpeakerElement(audio, reason);
}

// A connect binds new audio elements while iOS may still be rebuilding the
// audio session the previous connection tore down. The elements then report
// playing -- readyState 4, currentTime advancing, inbound-rtp showing real
// audio energy -- while nothing reaches the speaker: the same silent-renderer
// state a Siri interruption leaves behind, reached by a different route.
// Nothing on the connect path detects it, because the elements are not paused
// and so resumeSpeakerPlayback is a no-op. Rebuild them unconditionally once
// the session has had a moment to settle; twice, because how long that takes
// is not observable from script.
let connectReattachTimers = [];
function cancelConnectReattach() {
  for (const timer of connectReattachTimers) window.clearTimeout(timer);
  connectReattachTimers = [];
}

function scheduleConnectReattach(reason) {
  cancelConnectReattach();
  for (const delay of [250, 1_500]) {
    connectReattachTimers.push(window.setTimeout(() => {
      if (!connectionActive) return;
      void reattachSpeakerAudio(reason);
    }, delay));
  }
}

// A speaker who joins after connect gets an element built in exactly the state
// described above, and nothing covers it: scheduleConnectReattach has already
// run and will not run again, and resumeSpeakerPlayback is a no-op because the
// new element is not paused. It reports playing, its inbound-rtp carries real
// audio energy, and it stays silent until the page is reloaded. Give the new
// element the same double rebuild the connect path gives all of them, one
// element at a time so an already-audible speaker is never interrupted.
const speakerReattachTimers = new Map();
function cancelSpeakerReattach(audio) {
  for (const timer of speakerReattachTimers.get(audio) || []) window.clearTimeout(timer);
  speakerReattachTimers.delete(audio);
}

function scheduleSpeakerReattach(audio, reason) {
  cancelSpeakerReattach(audio);
  const timers = [];
  for (const delay of [250, 1_500]) {
    timers.push(window.setTimeout(() => {
      // The element may have been removed with its speaker in the meantime.
      if (!connectionActive || !speakerAudio.has(audio)) return;
      browserLog('reattaching new speaker', { reason, session: audio.dataset.session || null, delay });
      void reattachSpeakerElement(audio, reason);
    }, delay));
  }
  speakerReattachTimers.set(audio, timers);
}

// Rebuild what the interruption tore down, in dependency order: the audio
// session first, then the elements that render into it. Resuming the context
// alone was tried and is not enough -- it returns to 'running' and the speakers
// stay silent -- so the context state is a reliable detector of the
// interruption, and the reattach is the repair.
const AUDIO_RECOVERY_TIMEOUT_MS = 10_000;
let audioRecoveryWatchdog;
async function recoverAudio(reason) {
  if (audioRecoveryRunning || !connectionActive) return;
  audioRecoveryRunning = true;
  // This flag gates every future recovery, so it must never depend on a
  // promise settling. A resume() that never returned used to leave it latched
  // true for the life of the page, silently disabling recovery from then on.
  window.clearTimeout(audioRecoveryWatchdog);
  audioRecoveryWatchdog = window.setTimeout(() => {
    if (!audioRecoveryRunning) return;
    audioRecoveryRunning = false;
    // Whatever it was waiting on never arrived, so leave recovery armed for
    // the next visibility or focus event to retry.
    audioRecoveryNeeded = true;
    browserLog('audio recovery timed out', { reason, audioContext: audioProbe?.state ?? null });
  }, AUDIO_RECOVERY_TIMEOUT_MS);
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
    window.clearTimeout(audioRecoveryWatchdog);
    audioRecoveryWatchdog = undefined;
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
    const outcome = await withTimeout(audioProbe.resume(), AUDIO_RESUME_TIMEOUT_MS);
    if (outcome === TIMED_OUT) {
      browserLog('audio context resume timed out', { reason, state: audioProbe?.state ?? null });
    } else {
      browserLog('audio context resumed', { reason, state: audioProbe?.state ?? null });
    }
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
  for (const audio of article.querySelectorAll('audio')) {
    cancelSpeakerReattach(audio);
    speakerAudio.delete(audio);
  }
  article.remove();
}

function clearSpeakerArticles() {
  speakers.replaceChildren();
  for (const audio of speakerAudio.keys()) cancelSpeakerReattach(audio);
  speakerAudio.clear();
  speakerInfoByMid.clear();
  remoteTracksByMid.clear();
}

function labelSpeakerArticle(article, speaker) {
  const label = `${speaker.name} (session ${speaker.session})`;
  article.dataset.session = String(speaker.session);
  const heading = article.querySelector('h2');
  if (heading) heading.textContent = label;
  const audio = article.querySelector('audio');
  if (audio) {
    audio.title = label;
    audio.dataset.session = String(speaker.session);
  }
}

function createSpeakerArticle(mid, track, speaker, reason) {
  const label = `${speaker.name} (session ${speaker.session})`;
  browserLog('building speaker element', { mid, session: speaker.session, reason });
  const container = document.createElement('article');
  const heading = document.createElement('h2');
  heading.textContent = label;
  const audio = document.createElement('audio');
  audio.autoplay = true;
  audio.controls = true;
  audio.title = label;
  // Always a fresh MediaStream, never the one ontrack delivered: the gateway
  // answers a departed speaker's section inactive, which takes the track out of
  // that stream, and the section can be reclaimed by somebody else later.
  audio.srcObject = new MediaStream([track]);
  audio.dataset.trackId = track.id;
  audio.dataset.session = String(speaker.session);
  const volume = document.createElement('input');
  volume.type = 'range';
  volume.min = '0';
  volume.max = '100';
  volume.step = '1';
  volume.value = '100';
  volume.setAttribute('aria-label', 'Volume');
  volume.addEventListener('change', () => {
    const percent = Number(volume.value);
    audio.volume = Number.isFinite(percent) ? Math.min(100, Math.max(0, percent)) / 100 : 1;
  });
  audio.onplaying = () => browserLog('speaker audio playing', { track: track.id, session: speaker.session, readyState: audio.readyState, currentTime: metric(audio.currentTime) });
  audio.onwaiting = () => {
    browserLog('speaker audio waiting', { track: track.id, session: speaker.session, readyState: audio.readyState, currentTime: metric(audio.currentTime) });
    void resumeSpeakerPlayback('speaker audio waiting');
  };
  audio.onstalled = () => {
    browserLog('speaker audio stalled', { track: track.id, session: speaker.session });
    void resumeSpeakerPlayback('speaker audio stalled');
  };
  audio.onerror = () => browserLog('speaker audio error', { track: track.id, session: speaker.session, error: audio.error?.message });
  track.onmute = () => browserLog('remote track muted', { id: track.id, session: speaker.session });
  track.onunmute = () => browserLog('remote track unmuted', { id: track.id, session: speaker.session });
  container.dataset.session = String(speaker.session);
  container.dataset.mid = mid;
  container.append(heading, volume, audio);
  speakers.append(container);
  speakerAudio.set(audio, track);
  // A track that arrives while the audio session is interrupted cannot
  // autoplay, so ask for playback explicitly rather than trusting the
  // autoplay attribute.
  void resumeSpeakerPlayback('speaker element added');
  // ...and an element that does start playing can still be rendering into
  // nothing, which only a rebuild repairs.
  scheduleSpeakerReattach(audio, 'speaker element added');
}

// One article per assigned m= section. This runs both when a track arrives and
// when an answer assigns a speaker to a section whose track arrived earlier;
// the second case is the one spare sections made possible, and nothing else
// would ever build an element for it.
function syncSpeakerArticles(reason) {
  const existingByMid = new Map();
  for (const article of speakers.querySelectorAll('article')) existingByMid.set(article.dataset.mid, article);
  for (const [mid, track] of remoteTracksByMid) {
    const speaker = speakerInfoByMid.get(mid);
    // A spare section the gateway has not assigned to anybody yet.
    if (!speaker) continue;
    // The gateway never forgets a mid, so the channel roster is what decides
    // whether that speaker should still be on screen.
    if (currentChannelSessions.size && !currentChannelSessions.has(String(speaker.session))) continue;
    const existing = existingByMid.get(mid);
    if (existing) labelSpeakerArticle(existing, speaker);
    else createSpeakerArticle(mid, track, speaker, reason);
  }
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
// Everything the page does before connectSignalling() -- the microphone
// capture and the audio probe, which is exactly the window the connect-time
// silent-renderer bug lives in -- runs while socket is undefined. Dropping
// those lines left the gateway log with no record of the only part of a
// connect that can differ between a working and a silent one, so hold them
// until the socket opens instead.
const pendingLogs = [];
const PENDING_LOG_LIMIT = 200;
function browserLog(event, details = {}) {
  details.time = Date.now();
  console.info(`Wumble: ${event}`, details);
  if (socket?.readyState === WebSocket.OPEN) {
    signal({ type: 'log', event, details });
    return;
  }
  pendingLogs.push({ type: 'log', event, details });
  // A page that never connects must not grow this without bound.
  if (pendingLogs.length > PENDING_LOG_LIMIT) pendingLogs.shift();
}

function flushPendingLogs() {
  if (socket?.readyState !== WebSocket.OPEN || !pendingLogs.length) return;
  for (const entry of pendingLogs.splice(0, pendingLogs.length)) signal(entry);
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

// A user-initiated disconnect retains the capture (see suspendMicrophone), so
// re-arm that track rather than asking iOS for a new one. Stopping the last
// capture track tears down the page's audio session, and re-requesting it
// immediately is what races the new speaker elements into a dead renderer.
async function captureMicrophone(restart = false) {
  if (microphoneStream?.active && !restart) {
    const retained = microphoneStream.getAudioTracks()[0];
    if (retained?.readyState === 'live') {
      systemMicrophoneMuted = retained.muted;
      retained.enabled = !retained.muted;
      browserLog('microphone capture reused', { muted: retained.muted, enabled: retained.enabled });
      return;
    }
    // iOS can end a retained track on its own; fall through and recapture.
    browserLog('retained microphone capture was no longer live');
    stopMicrophone();
  }
  if (restart) stopMicrophone();
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('Microphone capture is not supported by this browser');
  // This is intentionally requested inside the Connect tap. While Safari is
  // capturing a MediaStream, it permits the remote WebRTC audio to autoplay.
  microphoneStream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    video: false,
  });
  const capturedStream = microphoneStream;
  const audioTrack = capturedStream.getAudioTracks()[0];
  systemMicrophoneMuted = audioTrack?.muted ?? false;
  if (audioTrack) {
    audioTrack.onmute = () => {
      if (microphoneStream !== capturedStream) return;
      systemMicrophoneMuted = true;
      audioTrack.enabled = false;
      // A system mute is the only unambiguous notice the page gets that iOS
      // took the audio session away, so it is what arms the recovery. Page
      // visibility alone is not: a desktop tab switch would then tear down and
      // rebuild every speaker element for nothing.
      audioRecoveryNeeded = true;
      browserLog('microphone muted by system', { muted: audioTrack.muted, enabled: audioTrack.enabled, readyState: audioTrack.readyState });
      if (socket?.readyState === WebSocket.OPEN) signal({ type: 'microphone_state', muted: true });
    };
    audioTrack.onunmute = () => {
      if (microphoneStream !== capturedStream) return;
      systemMicrophoneMuted = false;
      audioTrack.enabled = true;
      browserLog('microphone unmuted by system', { muted: audioTrack.muted, enabled: audioTrack.enabled, readyState: audioTrack.readyState });
      if (socket?.readyState === WebSocket.OPEN) signal({ type: 'microphone_state', muted: false });
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

// Disconnect without destroying the audio session. The capture stays live and
// only stops transmitting, which keeps iOS from tearing the session down and
// rebuilding it under the next connect's audio elements. The cost is that the
// system microphone indicator stays lit while disconnected.
function suspendMicrophone() {
  const audioTrack = microphoneStream?.getAudioTracks()[0];
  if (!audioTrack || audioTrack.readyState !== 'live') {
    stopMicrophone();
    return;
  }
  audioTrack.enabled = false;
  browserLog('microphone capture retained', { muted: audioTrack.muted, readyState: audioTrack.readyState });
}

function stopMicrophone() {
  const stream = microphoneStream;
  microphoneStream = undefined;
  stream?.getTracks().forEach((track) => {
    track.onmute = null;
    track.onunmute = null;
    track.stop();
  });
  systemMicrophoneMuted = false;
}

async function sendOffer(options = {}) {
  const offer = await peer.createOffer({ offerToReceiveAudio: true, ...options });
  await peer.setLocalDescription(offer);
  signal({ type: 'offer', sdp: offer.sdp });
}

// Recovering the path always beats tearing the session down. Closing the
// socket drops the Mumble connection, which re-authenticates and hands every
// speaker a new session ID and SSRC; an ICE restart keeps all of that.
const ICE_RESTART_DELAY_MS = 4_000;
const ICE_RESTART_LIMIT = 3;
const CONNECTION_GIVE_UP_MS = 25_000;
let iceRestartAttempts = 0;
let iceRestartInProgress = false;
let iceRestartTimer;
let connectionGiveUpTimer;

function clearConnectionRecovery() {
  window.clearTimeout(iceRestartTimer);
  window.clearTimeout(connectionGiveUpTimer);
  iceRestartTimer = undefined;
  connectionGiveUpTimer = undefined;
}

async function restartIce(reason) {
  const currentPeer = peer;
  if (!currentPeer || iceRestartInProgress) return;
  // A restart is itself an offer, so it cannot overlap another negotiation.
  if (currentPeer.signalingState !== 'stable') return;
  if (iceRestartAttempts >= ICE_RESTART_LIMIT) {
    browserLog('ICE restart limit reached; reconnecting', { reason, attempts: iceRestartAttempts });
    socket?.close();
    return;
  }
  iceRestartInProgress = true;
  iceRestartAttempts += 1;
  browserLog('ICE restart starting', {
    reason,
    attempt: iceRestartAttempts,
    connection: currentPeer.connectionState,
    ice: currentPeer.iceConnectionState,
  });
  try {
    await sendOffer({ iceRestart: true });
  } catch (error) {
    browserError('ICE restart failed', { reason, message: String(error) });
  } finally {
    iceRestartInProgress = false;
  }
}

// 'disconnected' is often a transient blip that the browser repairs on its
// own, so give it a moment before restarting, and only give up on the peer
// connection entirely once a restart has had time to work.
function scheduleConnectionRecovery(reason, delay = ICE_RESTART_DELAY_MS) {
  if (!iceRestartTimer) {
    iceRestartTimer = window.setTimeout(() => {
      iceRestartTimer = undefined;
      void restartIce(reason);
    }, delay);
  }
  if (!connectionGiveUpTimer) {
    connectionGiveUpTimer = window.setTimeout(() => {
      connectionGiveUpTimer = undefined;
      if (peer?.connectionState === 'connected') return;
      browserLog('media path did not recover; reconnecting', { reason, connection: peer?.connectionState ?? null });
      socket?.close();
    }, CONNECTION_GIVE_UP_MS);
  }
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
  clearConnectionRecovery();
  iceRestartAttempts = 0;
  iceRestartInProgress = false;
  // Every track belongs to the PeerConnection being replaced, so drop the old
  // elements rather than leaving dead ones for updateChannels to reap.
  clearSpeakerArticles();
  const currentPeer = new RTCPeerConnection({ iceServers: [] });
  peer = currentPeer;
  // The microphone goes on mid 0, in both directions: libdatachannel only
  // answers the offered sections it can pair with a local track, so the gateway
  // claims this one with a track of its own rather than leaving it unpaired and
  // answered inactive. Nothing is ever sent on the gateway's half, and the two
  // directions retain independent RTP streams and Opus packets regardless.
  peer.addTransceiver(microphoneStream.getAudioTracks()[0], { direction: 'sendrecv' });
  // Offer more receive-only sections than there are speakers. A Mumble user
  // who joins later can then be given a track straight away instead of the
  // gateway having to ask for another section first and wait for the offer
  // that carries it -- the two-phase handshake every "a speaker who joins is
  // silent" bug has come out of. Renegotiation still happens, to publish the
  // new section's SSRC, but it can no longer fail to find a section at all.
  // Idle sections cost nothing but a few lines of SDP.
  // One for the microphone, one per speaker the gateway already knows about.
  const sections = 1 + Math.max(0, speakerCount) + SPARE_SPEAKER_SECTIONS;
  for (let index = 1; index < sections; index += 1) {
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
      clearConnectionRecovery();
      iceRestartAttempts = 0;
    } else if (currentPeer.connectionState === 'disconnected') {
      scheduleConnectionRecovery('peer connection disconnected');
    } else if (currentPeer.connectionState === 'failed') {
      scheduleConnectionRecovery('peer connection failed', 0);
    }
  };
  currentPeer.oniceconnectionstatechange = () => {
    if (peer !== currentPeer) return;
    const details = { state: currentPeer.iceConnectionState };
    if (currentPeer.iceConnectionState === 'failed') {
      browserError('ICE failed', details);
      scheduleConnectionRecovery('ICE failed', 0);
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
    const mid = transceiver?.mid ?? '';
    browserLog('received remote track', { id: track.id, kind: track.kind, streams: streams.length, mid, speaker: speakerInfoByMid.get(mid) ?? null });
    // Do not combine tracks into one MediaStream. One received track means one
    // Mumble speaker and gets its own audio element and jitter buffer.
    remoteTracksByMid.set(mid, track);
    track.onended = () => {
      browserLog('remote track ended', { id: track.id, mid });
      remoteTracksByMid.delete(mid);
      for (const article of speakers.querySelectorAll('article')) {
        if (article.dataset.mid === mid) removeSpeakerArticle(article);
      }
    };
    syncSpeakerArticles('remote track');
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
    // Send the pre-connect backlog before this socket's own first line, so the
    // gateway log reads in the order the page produced it.
    flushPendingLogs();
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
      // An answer can assign a speaker to a spare section whose track arrived
      // in an earlier negotiation; no further ontrack fires for that section.
      syncSpeakerArticles('answer');
      setStatus('Connected');
      // Renegotiation answers land here too. Only the transition into a
      // connected state raced the audio session, so do not rebuild every
      // speaker's renderer each time somebody joins the channel.
      const wasConnected = connectionActive;
      setConnectionActive(true);
      channelSelect.disabled = false;
      if (!wasConnected) scheduleConnectReattach('connected');
      // A mute can outlive a signalling reconnect, so synchronize the new
      // gateway session even when iOS does not emit another mute event.
      if (systemMicrophoneMuted) signal({ type: 'microphone_state', muted: true });
      void requestWakeLock();
      await attemptRenegotiation();
    } else if (message.type === 'ice_restart') {
      // libdatachannel gave up on the path while this side still believes it
      // is connected, so do not wait for a local state change that will not
      // come.
      browserLog('gateway reported a lost media path', { reason: message.reason });
      await restartIce('gateway');
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
    cancelConnectReattach();
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
    cancelConnectReattach();
    // Keep the capture and the audio context across a user-initiated
    // disconnect. Closing either one destroys the page's audio session, and
    // the next connect then races its rebuild.
    suspendMicrophone();
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
