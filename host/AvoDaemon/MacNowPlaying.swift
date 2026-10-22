import AppKit
import AvoDaemonCore
import AvoProtocol
import MediaPlayer

/// What Android plays in the Mac's Now Playing: Control Center, the Lock
/// Screen, the media keys and AirPods' controls reach the app playing in
/// Android. Avo is the Mac's Now Playing app only while something plays
/// there: with nothing, it lets go of the commands, so the media keys go
/// back to the Mac's own apps.
///
/// macOS takes the playback state from the app (`playbackState`), not from
/// its audio, which Android's sound plays through avo-vmm.
final class MacNowPlaying: NowPlayingPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var onCommand: (@Sendable (Avo_V1_MediaCommand) -> Void)?
    /// Main thread only.
    private var registered = false
    private var artworkData: Data?
    private var artwork: MPMediaItemArtwork?

    func start(onCommand: @escaping @Sendable (Avo_V1_MediaCommand) -> Void) {
        lock.withLock { self.onCommand = onCommand }
    }

    func show(_ playing: Avo_V1_NowPlaying?, appName: String, artwork: Data?) {
        DispatchQueue.main.async { [self] in
            let center = MPNowPlayingInfoCenter.default()
            guard let playing else {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
                unregister()
                return
            }
            register()
            let commands = MPRemoteCommandCenter.shared()
            commands.nextTrackCommand.isEnabled = playing.canNext
            commands.previousTrackCommand.isEnabled = playing.canPrevious
            commands.changePlaybackPositionCommand.isEnabled = playing.canSeek && playing.durationMs > 0
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: playing.title.isEmpty ? appName : playing.title,
                // Android's player names the artist; a podcast or a video often does not.
                MPMediaItemPropertyArtist: playing.artist.isEmpty ? appName : playing.artist,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(playing.positionMs) / 1000,
                MPNowPlayingInfoPropertyPlaybackRate: playing.state == .playing ? Double(playing.speed) : 0,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            if !playing.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = playing.album }
            if playing.durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(playing.durationMs) / 1000 }
            if let artwork = self.artwork(for: artwork) { info[MPMediaItemPropertyArtwork] = artwork }
            center.nowPlayingInfo = info
            center.playbackState = switch playing.state {
            case .playing, .buffering: .playing
            case .paused: .paused
            default: .stopped
            }
        }
    }

    /// The same picture as last time keeps its artwork object.
    private func artwork(for data: Data?) -> MPMediaItemArtwork? {
        guard data != artworkData else { return artwork }
        artworkData = data
        artwork = data.flatMap(NSImage.init(data:)).map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        return artwork
    }

    private func register() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        let simple: [(MPRemoteCommand, Avo_V1_MediaCommand.Command)] = [
            (commands.playCommand, .play), (commands.pauseCommand, .pause), (commands.togglePlayPauseCommand, .toggle),
            (commands.nextTrackCommand, .next), (commands.previousTrackCommand, .previous), (commands.stopCommand, .stop),
        ]
        for (remote, command) in simple {
            remote.isEnabled = true
            remote.addTarget { [weak self] _ in
                var media = Avo_V1_MediaCommand()
                media.command = command
                return self?.send(media) ?? .commandFailed
            }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            var media = Avo_V1_MediaCommand()
            media.command = .seek
            media.positionMs = Int64(event.positionTime * 1000)
            return self?.send(media) ?? .commandFailed
        }
    }

    private func unregister() {
        guard registered else { return }
        registered = false
        let commands = MPRemoteCommandCenter.shared()
        for remote in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand, commands.nextTrackCommand,
                       commands.previousTrackCommand, commands.stopCommand, commands.changePlaybackPositionCommand] {
            remote.removeTarget(nil)
            remote.isEnabled = false
        }
        artworkData = nil
        artwork = nil
    }

    private func send(_ command: Avo_V1_MediaCommand) -> MPRemoteCommandHandlerStatus {
        guard let onCommand = lock.withLock({ onCommand }) else { return .commandFailed }
        onCommand(command)
        return .success
    }
}
