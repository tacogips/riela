# Video pipeline with yt-dlp

This package downloads media using `media/yt-dlp-download` and emits `mediaDownload.status` (`downloaded`) and an absolute `mediaDownload.path` for downstream consumers. Replace the downloader with any step or add-on that emits the same path.

Install with `riela package install video-pipeline-yt-dlp --source examples/video-pipeline-yt-dlp --working-dir <project>`. The installed workflow resolves its own add-on from the package. To project the add-on into `~/.riela/addons/<namespace>/<name>/<version>/` for other workflows, run `riela node install video-pipeline-yt-dlp --source examples/video-pipeline-yt-dlp --scope user`. Run `riela workflow run video-pipeline-yt-dlp --working-dir <project>`. Network egress is required; the container image builds automatically from its Containerfile and requires a container runtime.

After editing, refresh the content digest with `cat addons/yt-dlp-download/Containerfile addons/yt-dlp-download/yt-dlp-download | shasum -a 256`. Refresh the package checksum by copying the package to a temporary directory, running `riela package init <copy> --package-name video-pipeline-yt-dlp --overwrite`, and copying its checksum into the original manifest.
