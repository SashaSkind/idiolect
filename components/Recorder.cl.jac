"""Browser microphone capture for Idiolect."""

glob _recorder: any = None;
glob _chunks: list[any] = [];
glob _stream: any = None;


def:pub Recorder(
    disabled: bool,
    onAudio: Callable[[str, str], None],
) -> JsxElement {
    has recording: bool = False,
        elapsed: int = 0,
        timer_id: any = None,
        error_message: str = "";

    async def start_recording -> None {
        error_message = "";
        try {
            _stream = await navigator.mediaDevices.getUserMedia({"audio": True});
            _chunks = [];
            mime_type = (
                "audio/webm;codecs=opus"
                if MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
                else "audio/webm"
            );
            _recorder = new(MediaRecorder, _stream, {"mimeType": mime_type});
            _recorder.ondataavailable = lambda event: any {
                if event.data and event.data.size > 0 {
                    _chunks.append(event.data);
                }
            };
            _recorder.onstop = lambda {
                blob = new(Blob, _chunks, {"type": mime_type});
                reader = new(FileReader);
                reader.onloadend = lambda {
                    onAudio.call(None, str(reader.result), mime_type);
                };
                reader.readAsDataURL(blob);
                for track in _stream.getTracks() {
                    track.stop();
                }
                _stream = None;
                _recorder = None;
                _chunks = [];
            };
            _recorder.start();
            elapsed = 0;
            recording = True;
            timer_id = setInterval(lambda {
                elapsed = elapsed + 1;
            }, 1000);
        } except Exception {
            error_message = "Microphone access was blocked. Allow it in this browser and try again.";
            recording = False;
        }
    }

    def stop_recording -> None {
        if _recorder and _recorder.state == "recording" {
            _recorder.stop();
        }
        if timer_id {
            clearInterval(timer_id);
            timer_id = None;
        }
        recording = False;
    }

    return
        <div className="recorder">
            <button
                className={"record-button recording" if recording else "record-button"}
                disabled={disabled}
                onClick={stop_recording if recording else start_recording}
                aria-label={"Stop recording" if recording else "Start recording"}
            >
                <span className="record-icon"></span>
                <span>{("Stop · " + str(elapsed) + "s") if recording else "Start speaking"}</span>
            </button>
            <div className="wave-bars" aria-hidden="true">
                {for height in [12, 24, 17, 31, 20, 27, 14, 22, 10] {
                    <span
                        key={str(height)}
                        className={"active" if recording else ""}
                        style={{"height": str(height) + "px"}}
                    ></span>
                }}
            </div>
            {if error_message {
                <p className="inline-error">{error_message}</p>
            }}
            <p className="privacy-note">
                <span>●</span> Audio stays on this laptop
            </p>
        </div>;
}

