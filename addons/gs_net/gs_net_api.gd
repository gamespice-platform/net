extends RefCounted

## GameSpice Net's API level. The rule for bumping it is on [GSAddonApi]. LEVEL rises by one for anything a
## game could call that did not exist before.

# 7: GSNetClock.adopt_tick_rate(rate). 8: GSNetBehaviour.extrapolated_value(property, velocity_property, tick) and GSNetConfig.remote_extrapolation_sec. 17: GSNetVar.server_driven() / client_predicts.
# 18: GSNetInput.Buffer.push_batch(inputs), the lead measured per packet. 19: GSNetManager.snapshot_due(). 20: GSNetVar.Type.PACKED_FLOAT32 and of_length(count). 21: GSNetConfig.max_snapshot_parts. 22: GSNetIdentity.interest_aim and GSNetInterest.aim_cone_deg. 23: GSNetBehaviour.net_replaying.
# 24: GSNetInterpolator.track_samples / newest_tick / has_track and GSNetConfig.sim_interp_tracks_only. 25: GSNetInterpolator.bind_mirror / unbind_mirror / mirror_count (a copy-only _net_interpolated done natively) and GSNetBehaviour.listens_state_applied() (a snapshot apply skips the inherited no-op _net_state_applied).
# 26: GSNetConfig.skip_unchanged_state_applied (default on: _net_state_applied only when a read changed a value), GSNetBehaviour.state_applied_every_snapshot, GSNetSnapshotBatch.last_changed / hooks_skipped.
# 27: GSNetManager.set_native_core(core, note) / native_core() / native_note() (a game installs its own snapshot core).
const LEVEL := 27
const OLDEST := 1
