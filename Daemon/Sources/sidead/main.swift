import Foundation
import SideADaemonKit

exit(await DaemonCLI.main(Array(CommandLine.arguments.dropFirst())))
