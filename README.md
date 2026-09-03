# Wumble

Wumble is a Crystal server that bridges a Mumble connection to a browser through WebRTC using libdatachannel. The browser page is deliberately small, custom JavaScript.

Every Mumble Opus voice packet is put into an RTP packet and sent on the WebRTC audio section currently assigned to its Mumble session. Wumble never decodes, mixes, or combines speaker audio. A browser receives an independent `MediaStreamTrack` (and audio element) for each speaker.

Wumble is the side that offers; the browser only ever answers, and never adds a media section of its own. `m=audio` section 0 carries the browser's microphone. The rest are created one at a time, as speakers arrive, and are never pre-allocated. Their SSRCs belong to the sections rather than to the speakers, so a section left behind by someone who leaves is handed to the next arrival over the signalling socket, with no SDP change at all. Renegotiation therefore happens only when more people are in the channel at once than ever before, and the number of sections settles at that high-water mark -- WebRTC cannot remove an `m=` line from a session, so reusing them is what bounds the count.

## Prerequisites

Install Crystal plus the libdatachannel and libopus C libraries and headers through your operating system package manager. The libraries must be visible to the linker as `libdatachannel` and `libopus`.

```sh
crystal spec
python3 spec/integration/signalling_test.py
crystal build src/wumble.cr --release
./wumble
```

`crystal spec` covers the pieces in isolation. `spec/integration/signalling_test.py`
drives a built gateway through its two real interfaces -- a stub Mumble server and
a WebSocket client -- and checks that a join, a second join, a departure and a
rejoin each publish what they should. It needs `python3` and `openssl`, and it
exists because the gateway once shipped with every unit spec passing and no
speaker ever receiving an audio section. Pass `--binary` to test a gateway you
have already built.

Wumble listens on `/tmp/wumble.sock`, sets the socket group to `http`, and grants owner/group read-write access (`0660`). Point an HTTPS reverse proxy running as that group at the Unix socket, then open the proxy URL (HTTPS is required in production for iPhone microphone access, audio autoplay, and secure WebSocket access). Use `--socket` or `--group` to override the defaults. Connect sends the captured microphone as a WebRTC Opus stream; Wumble forwards its Opus payloads directly to Mumble without decoding or mixing. The connection fields are saved in the URL fragment when their inputs lose focus; fragments are not sent to the server, but passwords remain visible in browser history and copied links. Someone arriving in or leaving your channel plays a short two-tone cue -- rising for an arrival, falling for a departure -- synthesized in the browser and heard only by you. It is deliberately not the same path as the microphone-state cue, which is sent through Mumble as ordinary voice so the whole channel hears it. The first roster after connecting and a channel switch are adopted silently, so only an actual arrival or departure makes a sound. Mumble connection state and control packet names are written to stderr. Set `WUMBLE_DEBUG=1` to print backtraces and periodic WebRTC diagnostics, including selected ICE addresses, browser receiver callback/pipe/forwarding counts, accepted Opus sample counts, and track send-buffer sizes.

## Network and deployment

The gateway must be able to make TLS TCP connections to the selected Mumble server. libdatachannel also needs UDP reachable between the browser and gateway for WebRTC media. For internet clients, put the gateway on a public address or configure a TURN service in the libdatachannel configuration before deployment.

Mumble voice is carried as encrypted native UDP using the `CryptSetup` key material. Wumble sends encrypted UDP pings after authentication and accepts voice only after the server replies over UDP. If that path is unavailable after three seconds, the browser is alerted and no TCP `UDPTunnel` voice is forwarded. Ensure UDP on the selected Mumble port is reachable from the gateway.

## Design

- `src/wumble/mumble.cr`: TLS Mumble control connection and tunnel voice parser.
- `src/wumble/datachannel.cr`: minimal libdatachannel C binding and one RTP track per speaker.
- `src/wumble/server.cr`: HTTP static files and JSON WebSocket signalling.
- `web/`: custom browser UI; it does not import Mumble Web or any other Mumble client.

No Node build, generated web assets, or submodules are used.
