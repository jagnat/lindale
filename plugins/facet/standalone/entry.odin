package standalone_entry

import "../../../src/standalone_host"
import "../src"

main :: proc() {
	standalone_host.run()
}
