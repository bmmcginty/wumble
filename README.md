# Wumble

Wumble is a Crystal server that bridges a Mumble connection to a browser through WebRTC using libdatachannel. The browser page is deliberately small, custom JavaScript.

Every Mumble Opus voice packet is put into an RTP packet and sent on the WebRTC audio track assigned to its Mumble session ID. Wumble never decodes, mixes, or combines speaker audio. A browser receives an independent `MediaStreamTrack` (and audio element) for each speaker.

## Prerequisites

Install Crystal and the libdatachannel C library and headers through your operating system package manager. The library must be visible to the linker as `libdatachannel`.

```sh
crystal spec
crystal build src/wumble.cr --release
./wumble --bind 0.0.0.0 --port 8080
```

Open `http://gateway-host:8080/` (serve Wumble behind HTTPS in production for iPhone audio autoplay and secure WebSocket access). The form has the requested Mumble server, port, username, and password fields. Credentials are sent only over the signalling WebSocket and are never stored.

## Network and deployment

The gateway must be able to make TLS TCP connections to the selected Mumble server. libdatachannel also needs UDP reachable between the browser and gateway for WebRTC media. For internet clients, put the gateway on a public address or configure a TURN service in the libdatachannel configuration before deployment.

Mumble voice is carried as Opus. The current transport accepts server `UDPTunnel` voice packets, which is the TCP fallback Mumble servers provide when UDP is unavailable. Production deployments should enable the server's TCP tunnel fallback, or extend `MumbleConnection` with the Mumble CryptState UDP handshake for native UDP voice; neither option requires mixing audio.

## Design

- `src/wumble/mumble.cr`: TLS Mumble control connection and tunnel voice parser.
- `src/wumble/datachannel.cr`: minimal libdatachannel C binding and one RTP track per speaker.
- `src/wumble/server.cr`: HTTP static files and JSON WebSocket signalling.
- `web/`: custom browser UI; it does not import Mumble Web or any other Mumble client.

No Node build, generated web assets, or submodules are used.
