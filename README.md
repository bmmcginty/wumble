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

Open `http://gateway-host:8080/` (serve Wumble behind HTTPS in production for iPhone microphone access, audio autoplay, and secure WebSocket access). Connect requests microphone access even though transmission is not yet implemented: iPhone Safari allows the remote WebRTC tracks to autoplay while the page is capturing a `MediaStream`. Credentials are sent only over the signalling WebSocket and are never stored. Mumble connection state and control packet names are written to stderr. Set `WUMBLE_DEBUG=1` to print backtraces and periodic WebRTC outbound-media diagnostics, including selected ICE addresses, accepted Opus sample counts, and track send-buffer sizes.

## Network and deployment

The gateway must be able to make TLS TCP connections to the selected Mumble server. libdatachannel also needs UDP reachable between the browser and gateway for WebRTC media. For internet clients, put the gateway on a public address or configure a TURN service in the libdatachannel configuration before deployment.

Mumble voice is carried as encrypted native UDP using the `CryptSetup` key material. Wumble sends encrypted UDP pings after authentication and accepts voice only after the server replies over UDP. If that path is unavailable after three seconds, the browser is alerted and no TCP `UDPTunnel` voice is forwarded. Ensure UDP on the selected Mumble port is reachable from the gateway.

## Design

- `src/wumble/mumble.cr`: TLS Mumble control connection and tunnel voice parser.
- `src/wumble/datachannel.cr`: minimal libdatachannel C binding and one RTP track per speaker.
- `src/wumble/server.cr`: HTTP static files and JSON WebSocket signalling.
- `web/`: custom browser UI; it does not import Mumble Web or any other Mumble client.

No Node build, generated web assets, or submodules are used.
