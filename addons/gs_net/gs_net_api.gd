extends RefCounted

## GameSpice Net's API level. The rule for bumping it is on [GSAddonApi]. LEVEL rises by one for anything a
## game could call that did not exist before.

# 7: GSNetClock.adopt_tick_rate(rate). 8: GSNetBehaviour.extrapolated_value(property, velocity_property, tick) and GSNetConfig.remote_extrapolation_sec.
# 17: GSNetVar.server_driven() / client_predicts. 18: GSNetInput.Buffer.push_batch(inputs), the lead measured per packet. 19: GSNetManager.snapshot_due().
# 20: GSNetVar.Type.PACKED_FLOAT32 and of_length(count). 21: GSNetConfig.max_snapshot_parts. 22: GSNetIdentity.interest_aim and GSNetInterest.aim_cone_deg. 23: GSNetBehaviour.net_replaying.
# 24: GSNetInterpolator.track_samples(net_id) / newest_tick(net_id) / has_track(net_id) and GSNetConfig.sim_interp_tracks_only.
const LEVEL := 24
const OLDEST := 1
