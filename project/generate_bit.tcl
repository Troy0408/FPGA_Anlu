if {[catch {
import_device eagle_s20.db -package EG4S20BG256
open_project -single_run probe.al
import_db probe_route.db
bitgen -bit probe.bit
close_project
puts PLAYER720_CANDIDATE_BIT_DONE
} reason]} {puts stderr "PLAYER720_CANDIDATE_BIT_FAILED: $reason";exit 1}
exit 0
