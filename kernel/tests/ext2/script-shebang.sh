#!/bin/sh
# Started by pathname from ash. Nothing here names an interpreter: the
# kernel reads the line above out of this file and builds the argv the
# interpreter receives, so $0 must be this script and $* must be exactly
# what the caller typed after it.
echo "shebang: $0"
echo "shebang: args $*"
# A status the interpreter would never produce on its own, so the caller
# reading $? is reading THIS script's exit and not /bin/sh's.
exit 7
