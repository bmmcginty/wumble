const form = document.querySelector('#connect');
const status = document.querySelector('#status');
const speakers = document.querySelector('#speakers');
let socket;
let peer;
let heartbeat;

function setStatus(text) { status.textContent = text; }
function signal(message) { socket.send(JSON.stringify(message)); }

async function makeOffer() {
  peer = new RTCPeerConnection({ iceServers: [] });
  peer.onicecandidate = ({ candidate }) => {
    if (candidate) signal({ type: 'candidate', candidate: candidate.candidate, mid: candidate.sdpMid });
  };
  peer.ontrack = ({ track, streams }) => {
    // Do not combine tracks into one MediaStream. One received track means one
    // Mumble speaker and gets its own audio element and jitter buffer.
    const audio = document.createElement('audio');
    audio.autoplay = true;
    audio.controls = true;
    audio.srcObject = streams[0] || new MediaStream([track]);
    audio.dataset.trackId = track.id;
    speakers.append(audio);
    track.onended = () => audio.remove();
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
    // Keep reverse proxies from expiring an otherwise idle signalling socket.
    heartbeat = window.setInterval(() => signal({ type: 'ping' }), 20_000);
  };
  socket.onmessage = async ({ data }) => {
    const message = JSON.parse(data);
    if (message.type === 'pong') {
      return;
    } else if (message.type === 'connected') {
      await makeOffer();
    } else if (message.type === 'answer') {
      await peer.setRemoteDescription({ type: message.description_type, sdp: message.sdp });
      setStatus('Connected');
    } else if (message.type === 'candidate') {
      await peer.addIceCandidate({ candidate: message.candidate, sdpMid: message.mid });
    } else if (message.type === 'error') {
      setStatus(`Error: ${message.message}`);
      socket.close();
    }
  };
  socket.onerror = () => console.error('Wumble signalling WebSocket error');
  socket.onclose = ({ code, reason }) => {
    window.clearInterval(heartbeat);
    console.info(`Wumble signalling WebSocket closed (${code}: ${reason || 'no reason'})`);
    setStatus(`Disconnected (${code})`);
  };
});
