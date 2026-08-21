Three separate questions, so let me take them one at a time.

**Was it a libdatachannel bug?**

No, but it's a sharp edge. `disableAutoNegotiation` exists precisely so the application decides when the description is produced. We left auto-negotiation on and then added tracks after setting the remote offer, which is the one ordering that can't work. That's on us.

What I'd call a design flaw on their side is how quietly it fails. When libdatachannel answers an offered section it has no track for, it reciprocates it as `a=sendonly` anyway. So the answer promises the browser audio on that section but never says which stream carries it. A rejected section (port 0) would have been honest and the browser would have shown the speaker as dead immediately. Instead everything looked healthy — `ontrack` fired, the element said "playing" — and the packets went in the bin.

**Are we using it differently?**

Yes, and that's the deeper answer. The gateway is an answerer that needs to *add* outbound media over time. It can never offer, so it has to ask the browser to offer a spare section for every speaker who joins, then fill it. That inverted flow is unusual, and it's what makes the ordering matter at all. A libdatachannel media server normally either adds all tracks up front or is the offerer, and in both of those the question never arises.

**Is the whole thing overly complicated?**

Somewhat, and I think the git log shows it. "Fix speaker tracks that never arrive", "Discard WebRTC answers from replaced peers", "Reconcile speaker articles with channel membership", the duplicate-`ontrack` guard, the `renegotiation_pending` latch with the big warning comment — those are all the same design paying rent. Per-speaker tracks are worth keeping; renegotiating once per join is what costs.

Two ways to cut it down, cheapest first:

1. **Pre-allocate sections.** Have the browser offer, say, 8 recvonly sections at connect and assign speakers into free ones as they join. Renegotiation happens only when you run out, instead of every single join. Small change, keeps everything else, and this entire bug class mostly stops being reachable. Idle sections cost nothing meaningful.

2. **Make the gateway the offerer.** The side that has the media does the offering, which is the natural direction. `SpeakerTracks`, the renegotiate ping-pong, and the mid-availability bookkeeping largely go away, and adding a track then producing an offer is the ordering libdatachannel is built around. But it's a real rewrite of the signalling on both ends, and the system currently works.

If you want my recommendation: do (1) when you next touch this, and treat (2) as a rainy-day project rather than something worth destabilising a working gateway for.