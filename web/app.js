const form = document.querySelector('#connect');
const status = document.querySelector('#status');
const speakers = document.querySelector('#speakers');
let socket;
let peer;
let heartbeat;

function setStatus(text) { status.textContent = text; }
function signal(message) { socket.send(JSON.stringify(message)); }
function browserLog(event, details = {}) {
  console.info(`Wumble: ${event}`, details);
  if (socket?.readyState === WebSocket.OPEN) signal({ type: 'log', event, details });
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
  peer.onconnectionstatechange = () => browserLog('peer connection state', { state: peer.connectionState });
  peer.oniceconnectionstatechange = () => browserLog('ICE connection state', { state: peer.iceConnectionState });
  peer.onsignalingstatechange = () => browserLog('signalling state', { state: peer.signalingState });
  peer.ontrack = ({ track, streams }) => {
    browserLog('received remote track', { id: track.id, kind: track.kind, streams: streams.length });
    // Do not combine tracks into one MediaStream. One received track means one
    // Mumble speaker and gets its own audio element and jitter buffer.
    const audio = document.createElement('audio');
    audio.autoplay = true;
    audio.controls = true;
    audio.srcObject = streams[0] || new MediaStream([track]);
    audio.dataset.trackId = track.id;
    audio.onplaying = () => browserLog('speaker audio playing', { track: track.id });
    audio.onstalled = () => browserLog('speaker audio stalled', { track: track.id });
    audio.onerror = () => browserLog('speaker audio error', { track: track.id, error: audio.error?.message });
    speakers.append(audio);
    track.onended = () => { browserLog('remote track ended', { id: track.id }); audio.remove(); };
  };
  const offer = await peer.createOffer({ offerToReceiveAudio: true });
  await peer.setLocalDescription(offer);
  signal({ type: 'offer', sdp: offer.sdp });
}

form.addEventListener('submit', (event) => {
  event.preventDefault();
  const values = new FormData(form);
  const options = {
    server: values.get('server'),
    port: Number(values.get('port')),
    username: values.get('username'),
    password: values.get('password'),
  };
  socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/signal`);
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
      await peer.setRemoteDescription({ type: message.description_type, sdp: message.sdp });
      browserLog('accepted WebRTC answer', { sdpBytes: message.sdp.length });
      setStatus('Connected');
    } else if (message.type === 'candidate') {
      await peer.addIceCandidate({ candidate: message.candidate, sdpMid: message.mid });
    } else if (message.type === 'error') {
      setStatus(`Error: ${message.message}`);
      socket.close();
    }
  };
  socket.onerror = () => browserLog('signalling WebSocket error');
  socket.onclose = ({ code, reason }) => {
    window.clearInterval(heartbeat);
    console.info(`Wumble signalling WebSocket closed (${code}: ${reason || 'no reason'})`);
    setStatus(`Disconnected (${code})`);
  };
});
