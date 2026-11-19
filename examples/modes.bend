import Base
import ../src/videoio.bend as V
import ../src/modes.bend as M

def Modes.picked(choice: Maybe<&2, M.Mode>) -> String:
  match choice:
    case None{}:
      "nothing (no modes)"
    case Some{mode}:
      M.Mode.show(mode)

# Usage: modes
# Lists the default camera's modes and the one VideoCapture.open picks.
# Listing does not open the camera, so it needs no camera permission.

def Modes.report(listed: Result<&1, &1, U32 & String, List<&2, M.Mode>>) -> IO(Unit):
  match listed:
    case Fail{(code, message)}:
      do IO<Unit>:
        IO.print_err("Camera error " ++ U32.show(code) ++ ": " ++ message)
        IO.exit(1)
    case Done{+modes}:
      IO.print("Modes: " ++ M.Modes.show(modes) ++ "\nVideoCapture.open picks: " ++
        Modes.picked(M.Modes.pick(M.Largest{}, modes)))

def main() -> IO(Unit):
  IO.bind(Result<&1, &1, U32 & String, List<&2, M.Mode>>, Unit, V.VideoCapture.modes(0), listed =>
    Modes.report(listed))
