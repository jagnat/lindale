package standalone_entry

import "lindale:standalone_host"
import "../src"

main :: proc() {
	standalone_host.run()
}
