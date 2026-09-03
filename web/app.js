const form = document.querySelector('#connect');
const status = document.querySelector('#status');
const speakers = document.querySelector('#speakers');
const channelControl = document.querySelector('#channel-control');
const channelSelect = document.querySelector('#channel');
const connectionToggle = document.querySelector('#connection-toggle');
const messageForm = document.querySelector('#message-form');
const messageInput = document.querySelector('#message-input');
const messageSend = document.querySelector('#message-send');
const messageLog = document.querySelector('#message-log');
let socket;
let peer;
let heartbeat;
let statsTimer;
let microphoneStream;
let systemMicrophoneMuted = false;
let connectionOptions;
let reconnectTimer;
let reconnectAttempts = 0;
let reconnectEnabled = false;
let connectionActive = false;
let wakeLock;
// mid -> the section the gateway has assigned to that m= line: its SSRC, the
// Mumble session holding it, and that session's name. The gateway sends this
// whenever it changes; it is the only thing that decides which audio element
// exists and what it is called.
const speakerInfoByMid = new Map();
// The gateway offers mid 0 as recvonly, so this is the section this side
// sends its microphone on. Every other section is the gateway's to send.
const MICROPHONE_MID = '0';
// Element -> the remote track it plays. The track is kept because reattaching
// after an interruption has to build a new MediaStream around the same track.
const speakerAudio = new Map();
// mid -> the remote track ontrack delivered for that m= section. ontrack fires
// once per section and never again, and a section outlives the speakers that
// pass through it, so the track is held here and elements are built from it as
// the gateway hands the section from one speaker to the next.
const remoteTracksByMid = new Map();
let playbackResumeRunning = false;
let audioProbe;
// A second context, separate from audioProbe on purpose: the probe has nothing
// connected to it so its state is a clean read on the page's audio session,
// and the join/leave cues are the page's own sound rather than speaker audio.
let cueContext;
// session -> name for the channel the gateway last reported. Join and leave
// cues are the difference between this and the next roster, so it starts empty
// and is replaced without a sound whenever the whole membership changes at
// once: the snapshot after connecting, and a channel switch.
let knownChannelUsers;
let knownChannel;
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

// Join and leave cues are heard by this browser only. They are synthesized
// here rather than sent through Mumble like the microphone-state cue, because
// the rest of the channel has no reason to hear who arrived on this page's
// screen reader. Two 120 ms notes: rising for an arrival, falling for a
// departure.
const CUE_NOTE_SECONDS = 0.12;
const CUE_LOW_HZ = 440;
const CUE_HIGH_HZ = 880;
const CUE_GAIN = 0.14;
function startCueContext() {
  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  if (cueContext || !AudioContextClass) return;
  cueContext = new AudioContextClass();
  browserLog('cue context created', { state: cueContext.state });
}

function stopCueContext() {
  if (!cueContext) return;
  const context = cueContext;
  cueContext = undefined;
  void context.close().catch(() => {});
}

function playPresenceCue(rising) {
  if (!cueContext) return;
  // A context suspended by an interruption or by autoplay policy resumes on
  // its own once the page is interactive again; a failed cue is not worth
  // reporting as an error, only as a missed sound.
  if (cueContext.state !== 'running') void cueContext.resume().catch(() => {});
  try {
    const start = cueContext.currentTime;
    const gain = cueContext.createGain();
    gain.connect(cueContext.destination);
    // Match the Mumble-side cue's short attack and release so neither note
    // clicks, and so the two cues sound like the same instrument.
    const notes = rising ? [CUE_LOW_HZ, CUE_HIGH_HZ] : [CUE_HIGH_HZ, CUE_LOW_HZ];
    gain.gain.setValueAtTime(0, start);
    notes.forEach((frequency, index) => {
      const noteStart = start + index * CUE_NOTE_SECONDS;
      const oscillator = cueContext.createOscillator();
      oscillator.type = 'sine';
      oscillator.frequency.setValueAtTime(frequency, noteStart);
      oscillator.connect(gain);
      oscillator.start(noteStart);
      oscillator.stop(noteStart + CUE_NOTE_SECONDS);
      gain.gain.linearRampToValueAtTime(CUE_GAIN, noteStart + 0.005);
      gain.gain.setValueAtTime(CUE_GAIN, noteStart + CUE_NOTE_SECONDS - 0.005);
    });
    gain.gain.linearRampToValueAtTime(0, start + notes.length * CUE_NOTE_SECONDS);
  } catch (error) {
    browserLog('presence cue failed', { rising, message: String(error) });
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

// One article per assigned m= section, built entirely from what the gateway
// last said. A section with no speaker has no article; a section that changed
// hands is relabelled in place, because its track and its SSRC did not change.
function applySections(sections, reason) {
  speakerInfoByMid.clear();
  for (const section of sections || []) speakerInfoByMid.set(section.mid, section);
  for (const article of speakers.querySelectorAll('article')) {
    if (speakerInfoByMid.has(article.dataset.mid)) continue;
    browserLog('removing departed speaker', { mid: article.dataset.mid || null, session: article.dataset.session || null });
    removeSpeakerArticle(article);
  }
  syncSpeakerArticles(reason);
}

function syncSpeakerArticles(reason) {
  const existingByMid = new Map();
  for (const article of speakers.querySelectorAll('article')) existingByMid.set(article.dataset.mid, article);
  for (const [mid, speaker] of speakerInfoByMid) {
    const track = remoteTracksByMid.get(mid);
    // The gateway can name a section in the same breath as creating it. Its
    // track arrives with the offer that follows, and this runs again then.
    if (!track) continue;
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
  setMessagingEnabled(active);
}
function signal(message) { socket.send(JSON.stringify(message)); }
// The channel list only. Which speakers exist and what they are called comes
// from the gateway's section mapping, so this no longer touches the articles:
// the roster and the sections used to race, and whichever arrived second won.
function updateChannels({ current_channel: currentChannel, channels, users }) {
  const selected = String(currentChannel ?? '');
  updatePresence(currentChannel, users);
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
}
// Who is in the channel, purely so an arrival or a departure can be heard.
// Nothing visual depends on this: the articles come from the gateway's section
// mapping. A whole-membership change -- the first roster after connecting, and
// a channel switch -- is adopted silently, because a burst of cues for people
// who were already there says nothing about who just moved.
function updatePresence(currentChannel, users) {
  const roster = new Map((users || []).map((user) => [user.session, user.name]));
  const wholesale = knownChannelUsers === undefined || currentChannel !== knownChannel;
  const previous = knownChannelUsers;
  knownChannelUsers = roster;
  knownChannel = currentChannel;
  if (wholesale) {
    browserLog('channel roster adopted without cues', { channel: currentChannel ?? null, users: roster.size });
    return;
  }
  for (const [session, name] of roster) {
    if (!previous.has(session)) {
      browserLog('speaker joined the channel', { session, name });
      playPresenceCue(true);
    }
  }
  for (const [session, name] of previous) {
    if (!roster.has(session)) {
      browserLog('speaker left the channel', { session, name });
      playPresenceCue(false);
    }
  }
}

function forgetPresence() {
  knownChannelUsers = undefined;
  knownChannel = undefined;
}

// Mumble carries text as HTML. Rendering it would mean trusting markup from
// anyone on the server, and a screen reader reads a flattened line more
// predictably anyway, so parse it in an inert document and keep only the text
// -- plus each link's URL, which is the one thing flattening would otherwise
// throw away.
const MESSAGE_LOG_LIMIT = 200;
function messageToText(html) {
  const parts = [];
  const walk = (node) => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        parts.push(child.nodeValue);
        continue;
      }
      if (child.nodeType !== Node.ELEMENT_NODE) continue;
      const tag = child.tagName.toLowerCase();
      if (tag === 'br') {
        parts.push('\n');
        continue;
      }
      if (tag === 'a') {
        const text = child.textContent.trim();
        const href = (child.getAttribute('href') || '').trim();
        if (href && href !== text) parts.push(text ? `${text} (${href})` : href);
        else parts.push(text || href);
        continue;
      }
      walk(child);
      if (tag === 'p' || tag === 'div' || tag === 'li') parts.push('\n');
    }
  };
  try {
    walk(new DOMParser().parseFromString(html, 'text/html').body);
  } catch (error) {
    browserLog('message parse failed', { message: String(error) });
    return html;
  }
  return parts.join('').replace(/\n{3,}/g, '\n\n').trim();
}

// One line per message in the live region. textContent throughout: the sender
// name comes from the server too, so it gets the same treatment as the body.
function appendMessage(sender, body, { private: privateMessage = false } = {}) {
  const line = document.createElement('p');
  const label = document.createElement('span');
  label.className = privateMessage ? 'sender private' : 'sender';
  label.textContent = privateMessage ? `${sender} (private): ` : `${sender}: `;
  line.append(label, document.createTextNode(body));
  messageLog.append(line);
  while (messageLog.childElementCount > MESSAGE_LOG_LIMIT) messageLog.firstElementChild.remove();
  messageLog.scrollTop = messageLog.scrollHeight;
}

function setMessagingEnabled(enabled) {
  messageInput.disabled = !enabled;
  messageSend.disabled = !enabled;
}

messageForm.addEventListener('submit', (event) => {
  event.preventDefault();
  const body = messageInput.value.trim();
  if (!body || !connectionActive || socket?.readyState !== WebSocket.OPEN) return;
  signal({ type: 'send_text', message: body });
  // Murmur does not echo a message back to its sender, so the only record of
  // what was sent is the one made here.
  appendMessage('You', body);
  messageInput.value = '';
  messageInput.focus();
});

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

// Recovering the media path always beats tearing the session down: closing the
// socket drops the Mumble connection, which re-authenticates and hands every
// speaker a new session ID. The gateway owns that recovery -- it is the only
// side that offers, and it rebuilds its peer connection when libdatachannel
// gives up -- so this side only has to notice when nothing recovers at all.
const CONNECTION_GIVE_UP_MS = 25_000;
let connectionGiveUpTimer;

function clearConnectionRecovery() {
  window.clearTimeout(connectionGiveUpTimer);
  connectionGiveUpTimer = undefined;
}

function scheduleConnectionRecovery(reason) {
  if (connectionGiveUpTimer) return;
  connectionGiveUpTimer = window.setTimeout(() => {
    connectionGiveUpTimer = undefined;
    if (peer?.connectionState === 'connected') return;
    browserLog('media path did not recover; reconnecting', { reason, connection: peer?.connectionState ?? null });
    socket?.close();
  }, CONNECTION_GIVE_UP_MS);
}

// Every m= section belongs to the gateway: it offers, this side answers, and
// this side never adds a transceiver of its own. There is therefore no local
// negotiation state to keep, no renegotiation to request, and no way for the
// two sides to offer at once.
function createPeerConnection() {
  clearConnectionRecovery();
  clearSpeakerArticles();
  const currentPeer = new RTCPeerConnection({ iceServers: [] });
  peer = currentPeer;
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
    } else if (currentPeer.connectionState === 'disconnected' || currentPeer.connectionState === 'failed') {
      scheduleConnectionRecovery(`peer connection ${currentPeer.connectionState}`);
    }
  };
  currentPeer.oniceconnectionstatechange = () => {
    if (peer !== currentPeer) return;
    const details = { state: currentPeer.iceConnectionState };
    if (currentPeer.iceConnectionState === 'failed') {
      browserError('ICE failed', details);
      scheduleConnectionRecovery('ICE failed');
    } else browserLog('ICE connection state', details);
  };
  currentPeer.onicecandidateerror = ({ url, errorCode, errorText }) => {
    if (peer === currentPeer) browserError('ICE candidate error', { url, errorCode, errorText });
  };
  currentPeer.onsignalingstatechange = () => {
    if (peer === currentPeer) browserLog('signalling state', { state: currentPeer.signalingState });
  };
  currentPeer.ontrack = ({ track, streams, transceiver }) => {
    if (peer !== currentPeer) return;
    const mid = transceiver?.mid ?? '';
    browserLog('received remote track', { id: track.id, kind: track.kind, streams: streams.length, mid, speaker: speakerInfoByMid.get(mid) ?? null });
    // Do not combine tracks into one MediaStream. One section means one
    // speaker at a time and gets its own audio element and jitter buffer.
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
  return currentPeer;
}

// The gateway offers mid 0 as recvonly, so this side's transceiver for it is
// already sendonly and only wants a track. Attaching it here rather than
// declaring it up front is what lets the gateway decide every section.
async function attachMicrophone(currentPeer) {
  const track = microphoneStream?.getAudioTracks()[0];
  const transceiver = currentPeer.getTransceivers().find((entry) => entry.mid === MICROPHONE_MID);
  if (!transceiver) {
    browserError('microphone section missing from the gateway offer', { mids: currentPeer.getTransceivers().map((entry) => entry.mid) });
    return;
  }
  // Derived from the gateway's recvonly offer, but set it explicitly rather
  // than trusting every browser to reverse the direction the same way.
  if (transceiver.direction !== 'sendonly') transceiver.direction = 'sendonly';
  if (!track) return;
  if (transceiver.sender.track === track) return;
  await transceiver.sender.replaceTrack(track);
  browserLog('microphone attached', { mid: transceiver.mid, direction: transceiver.direction });
}

async function acceptOffer(message) {
  const currentPeer = peer || createPeerConnection();
  // Name the sections before the remote description, because ontrack fires
  // while it is being applied and builds elements from this mapping.
  speakerInfoByMid.clear();
  for (const section of message.sections || []) speakerInfoByMid.set(section.mid, section);
  await currentPeer.setRemoteDescription({ type: 'offer', sdp: message.sdp });
  await attachMicrophone(currentPeer);
  const answer = await currentPeer.createAnswer();
  await currentPeer.setLocalDescription(answer);
  if (peer !== currentPeer) {
    browserLog('discarding answer from a replaced peer connection');
    return;
  }
  signal({ type: 'answer', sdp: answer.sdp });
  browserLog('answered gateway offer', { sdpBytes: answer.sdp.length, sections: speakerInfoByMid.size });
  applySections(message.sections, 'offer');
  setStatus('Connected');
  // Only the transition into a connected state races the audio session, so do
  // not rebuild every speaker's renderer each time somebody joins the channel.
  const wasConnected = connectionActive;
  setConnectionActive(true);
  channelSelect.disabled = false;
  if (!wasConnected) scheduleConnectReattach('connected');
  // A mute can outlive a signalling reconnect, so synchronize the new gateway
  // session even when iOS does not emit another mute event.
  if (systemMicrophoneMuted) signal({ type: 'microphone_state', muted: true });
  void requestWakeLock();
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
    } else if (message.type === 'channel_state') {
      updateChannels(message);
    } else if (message.type === 'offer') {
      await acceptOffer(message);
    } else if (message.type === 'text_message') {
      const body = messageToText(message.message || '');
      if (body) appendMessage(message.name, body, { private: message.private });
    } else if (message.type === 'sections') {
      // A section changed hands. Nothing in the SDP changed with it, because
      // the SSRCs belong to the sections rather than to the speakers.
      applySections(message.sections, 'sections');
    } else if (message.type === 'media_restart') {
      // libdatachannel gave up on the path and rebuilt its peer connection.
      // Drop this side's and wait for the offer that follows.
      browserLog('gateway rebuilt the media path', { reason: message.reason });
      peer?.close();
      peer = undefined;
      speakerInfoByMid.clear();
      clearSpeakerArticles();
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
    clearConnectionRecovery();
    cancelConnectReattach();
    forgetPresence();
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
      stopCueContext();
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
    clearConnectionRecovery();
    window.clearInterval(heartbeat);
    window.clearInterval(statsTimer);
    cancelConnectReattach();
    // Keep the capture and the audio context across a user-initiated
    // disconnect. Closing either one destroys the page's audio session, and
    // the next connect then races its rebuild.
    suspendMicrophone();
    audioRecoveryNeeded = false;
    stopCueContext();
    forgetPresence();
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
  startCueContext();
  connectSignalling();
});
