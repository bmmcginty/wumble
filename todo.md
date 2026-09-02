Wumble's WebRTC signalling was rewritten in the "Make the gateway the WebRTC
offerer" commit. What follows is the reasoning that led there, kept because it
explains why the code looks the way it does.

**Was it a libdatachannel bug?**

No, but it is a sharp edge. `disableAutoNegotiation` exists precisely so the
application decides when the description is produced. We left auto-negotiation
on and then added tracks after setting the remote offer, which is the one
ordering that cannot work. That was on us.

What is a design flaw on their side is how quietly it fails. When libdatachannel
answers an offered section it has no track for, it reciprocates it as
`a=sendonly` anyway. So the answer promises the browser audio on that section
but never says which stream carries it. A rejected section (port 0) would have
been honest and the browser would have shown the speaker as dead immediately.
Instead everything looked healthy -- `ontrack` fired, the element said
"playing" -- and the packets went in the bin.

**Were we using it differently?**

Yes, and that was the deeper answer. The gateway was an answerer that needed to
*add* outbound media over time. It could never offer, so it had to ask the
browser to offer a spare section for every speaker who joined, then fill it.
That inverted flow is unusual, and it is what made the ordering matter at all. A
libdatachannel media server normally either adds all tracks up front or is the
offerer, and in both of those the question never arises.

**Was the whole thing overly complicated?**

Yes, and the git log showed it. "Fix speaker tracks that never arrive",
"Discard WebRTC answers from replaced peers", "Reconcile speaker articles with
channel membership", the duplicate-`ontrack` guard, the `renegotiation_pending`
latch with the big warning comment -- all the same design paying rent.
Per-speaker sections are worth keeping; renegotiating once per join is what
cost.

**What was done instead**

The gateway offers. Sections are created on demand, one per speaker, and never
pre-allocated: a fixed pool would reserve capacity for a worst case that
usually does not happen. Their SSRCs are fixed to the section rather than to
the speaker, which is what lets a section change hands with a signalling
message instead of a renegotiation, so the pool's one advantage is kept without
its cost.

Two things were considered and rejected along the way:

1. **Mixing server-side.** One track, no renegotiation ever, but it costs a
   decode/encode hop and the per-speaker volume and jitter buffers the design
   exists for.

2. **Perfect negotiation with both sides offering.** libdatachannel 0.24 has no
   rollback and no ICE restart, so a glare collision would be unrecoverable.
   Instead the gateway is the only side that ever offers, and a lost media path
   is repaired by rebuilding the peer connection rather than restarting ICE.
