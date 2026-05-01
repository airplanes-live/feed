#!/bin/bash

#####################################################################################
#                        airplanes.live SETUP SCRIPT                                #
#####################################################################################
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#                                                                                   #
# Copyright (c) 2023 AirDG                                                          #
#                                                                                   #
# Permission is hereby granted, free of charge, to any person obtaining a copy      #
# of this software and associated documentation files (the "Software"), to deal     #
# in the Software without restriction, including without limitation the rights      #
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell         #
# copies of the Software, and to permit persons to whom the Software is             #
# furnished to do so, subject to the following conditions:                          #
#                                                                                   #
# The above copyright notice and this permission notice shall be included in all    #
# copies or substantial portions of the Software.                                   #
#                                                                                   #
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR        #
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,          #
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE       #
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER            #
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,     #
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE     #
# SOFTWARE.                                                                         #
#                                                                                   #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/install-update-common.sh
source "$SCRIPT_DIR/scripts/lib/install-update-common.sh"
airplanes_enable_build_mode_from_args "$@"
airplanes_init_paths

## we need to install stuff that require root, check for that
airplanes_require_root

## REFUSE INSTALLATION ON AIRPLANES.LIVE IMAGE

if ! airplanes_is_build_mode && airplanes_is_image_install; then
    echo --------
    echo "You are using the airplanes.live image, the feed setup script does not need to be installed."
    echo "You should already be feeding."
    echo "If the feed isn't working, check/correct the configuration using nano:"
    echo --------
    echo "sudo nano /etc/airplanes/feed.env"
    echo --------
    echo "Hint for using nano: Ctrl-X to exit, Y(yes) and Enter to save."
    echo --------
    echo "Exiting."
    exit 1
fi

bash "$IPATH/git/configure.sh" "$@"

BACKTITLETEXT="${BACKTITLETEXT:-airplanes.live Setup Script}"
if ! airplanes_is_build_mode; then
    whiptail --backtitle "$BACKTITLETEXT" --title "$BACKTITLETEXT" --yesno "We are now ready to begin setting up your receiver to feed airplanes.live.\n\nDo you wish to proceed?" 9 78 || exit 1
fi

bash "$IPATH/git/update.sh" "$@"

exit 0
