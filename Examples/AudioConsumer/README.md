# Independent capture-product consumer

`swift run --package-path Examples/AudioConsumer AudioConsumer` builds and links
only the `HDXLVoiceProcessingAudio` product and its Core dependency. The example
constructs capture-buffering metadata; it does not request permission, inspect
devices, configure an audio session or start an engine.

`Tools/verify-package-graph.py` checks its product dependency, forbidden UI imports
in Core/Audio, and linked libraries alongside `Examples/CoreConsumer`.
`Tools/build-ios.sh` compiles both independent consumers for the declared iOS 27
device and Simulator destinations. The minimum macOS version is 27.
