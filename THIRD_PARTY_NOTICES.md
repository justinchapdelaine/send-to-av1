# Third-party notices

## FFmpeg

Send to AV1 uses FFmpeg and FFprobe when they are available on the user's system or placed in the local `bin` folder.

The source repository does not include FFmpeg binaries.

FFmpeg is a separate project:

- Website: https://ffmpeg.org/
- Legal information: https://ffmpeg.org/legal.html
- Download information: https://ffmpeg.org/download.html

FFmpeg is generally licensed under the GNU Lesser General Public License version 2.1 or later, but FFmpeg builds that include GPL-covered components may be licensed under the GNU General Public License.

If this project later publishes a portable release that bundles FFmpeg binaries, that release should include:

- the FFmpeg license text
- the exact FFmpeg version/build source
- a clear source-code or build-information reference for the bundled binaries
- any notices required by the chosen FFmpeg build provider

Users may also provide their own FFmpeg build by placing `ffmpeg.exe` and optionally `ffprobe.exe` in the local `bin` folder.

## BtbN FFmpeg Builds

`src/Download-FFmpeg.ps1` can download BtbN GPL FFmpeg builds from GitHub releases and install `ffmpeg.exe` and `ffprobe.exe` into the local `bin` folder.

- Project: https://github.com/BtbN/FFmpeg-Builds
- Releases: https://github.com/BtbN/FFmpeg-Builds/releases

Downloaded binaries are not committed to this source repository.
