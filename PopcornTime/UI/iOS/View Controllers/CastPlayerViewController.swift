

import UIKit
import PopcornTorrent
import GoogleCast
import JGProgressHUD
import SwiftyTimer
import PopcornKit


class CastPlayerViewController: UIViewController, GCKRemoteMediaClientListener {
    
    @IBOutlet var progressSlider: ProgressSlider!
    @IBOutlet var volumeSlider: UISlider?
    @IBOutlet var closeButton: BlurButton!
    @IBOutlet var imageView: UIImageView!
    @IBOutlet var backgroundImageView: UIImageView!
    @IBOutlet var elapsedTimeLabel: UILabel!
    @IBOutlet var remainingTimeLabel: UILabel!
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var playPauseButton: UIButton!
    @IBOutlet var compactConstraints: [NSLayoutConstraint]!
    @IBOutlet var regularConstraints: [NSLayoutConstraint]!
    
    private var classContext = 0
    private var elapsedTimer: Timer!
    private var observingValues: Bool = false
    private var bufferView: JGProgressHUD = {
       let hud = JGProgressHUD(style: .dark)
        hud?.textLabel.text = "Buffering"
        hud?.interactionType = .blockAllTouches
        return hud!
    }()
    private var subtitleColors: [String: UIColor] = {
        var colorDict = [String: UIColor]()
        for (index, color) in UIColor.systemColors.enumerated() {
            colorDict[UIColor.systemColorStrings[index]] = color
        }
        return colorDict
    }()
    private var subtitleFonts: [String: UIFont] = {
        var fontDict = [String: UIFont]()
        for familyName in UIFont.familyNames {
            for fontName in UIFont.fontNames(forFamilyName: familyName) {
                let font = UIFont(name: fontName, size: 25)!; let traits = font.fontDescriptor.symbolicTraits
                if !traits.contains(.traitCondensed) && !traits.contains(.traitBold) && !traits.contains(.traitItalic) && !fontName.contains("Thin") && !fontName.contains("Light") && !fontName.contains("Medium") && !fontName.contains("Black") {
                    fontDict[fontName] = UIFont(name: fontName, size: 25)
                }
            }
        }
        fontDict["Default"] = UIFont.systemFont(ofSize: 25)
        return fontDict
    }()
    private var subtitles = ["None": ""]
    private var selectedSubtitleMeta: [String]
    
    var backgroundImage: UIImage?
    var startPosition: TimeInterval = 0.0
    var media: Media! {
        didSet {
            if let subtitles = media.subtitles {
                var subtitleDict = [String: String]()
                for subtitle in subtitles {
                    subtitleDict[subtitle.language] = subtitle.link
                }
                self.subtitles += subtitleDict
                self.selectedSubtitleMeta[0] = media.currentSubtitle?.language ?? UserDefaults.standard.string(forKey: "PreferredSubtitleLanguage") ?? "None"
            }
        }
    }
    var directory: URL!
    
    private var remoteMediaClient = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    private var timeSinceLastMediaStatusUpdate: TimeInterval {
        if let remoteMediaClient = remoteMediaClient , state == .playing {
            return remoteMediaClient.timeSinceLastMediaStatusUpdate
        }
        return 0.0
    }
    private var streamPosition: TimeInterval {
        get {
            if let mediaStatus = remoteMediaClient?.mediaStatus {
                return mediaStatus.streamPosition + timeSinceLastMediaStatusUpdate
            }
            return 0.0
        } set {
            remoteMediaClient?.seek(toTimeInterval: newValue, resumeState: GCKMediaResumeState.play)
        }
    }
    private var state: GCKMediaPlayerState {
        return remoteMediaClient?.mediaStatus?.playerState ?? GCKMediaPlayerState.unknown
    }
    private var idleReason: GCKMediaPlayerIdleReason {
        return remoteMediaClient?.mediaStatus?.idleReason ?? GCKMediaPlayerIdleReason.none
    }
    private var streamDuration: TimeInterval {
        return remoteMediaClient?.mediaStatus?.mediaInformation?.streamDuration ?? 0.0
    }
    private var elapsedTime: VLCTime {
        return VLCTime(number: NSNumber(value: streamPosition * 1000 as Double))
    }
    private var remainingTime: VLCTime {
        return VLCTime(number: NSNumber(value: (streamPosition - streamDuration) * 1000 as Double))
    }
    
    @IBAction func playPause(_ sender: UIButton) {
        if state == .paused {
            remoteMediaClient?.play()
        } else if state == .playing {
            remoteMediaClient?.pause()
        }
    }
    
    @IBAction func rewind() {
        streamPosition -= 30
    }
    
    @IBAction func fastForward() {
        streamPosition += 30
    }
    
    @IBAction func subtitles(_ sender: UIButton) {
        //pickerView.toggle()
    }
    
    @IBAction func volumeSliderAction() {
        remoteMediaClient?.setStreamVolume(volumeSlider!.value)
    }
    
    @IBAction func progressSliderAction() {
        streamPosition += (TimeInterval(progressSlider.value) * streamDuration)
    }
    
    @IBAction func progressSliderDrag() {
        remoteMediaClient?.pause()
        elapsedTimeLabel.text = VLCTime(number: NSNumber(value: ((TimeInterval(progressSlider.value) * streamDuration)) * 1000 as Double)).stringValue
        remainingTimeLabel.text = VLCTime(number: NSNumber(value: (((TimeInterval(progressSlider.value) * streamDuration) - streamDuration)) * 1000 as Double)).stringValue
    }
    
    @IBAction func close() {
        if observingValues {
            remoteMediaClient?.mediaStatus?.removeObserver(self, forKeyPath: "playerState")
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        remoteMediaClient?.stop()
        PTTorrentStreamer.shared().cancelStreamingAndDeleteData(UserDefaults.standard.bool(forKey: "removeCacheOnPlayerExit"))
        dismiss(animated: true, completion: nil)
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        for constraint in compactConstraints {
            constraint.priority = traitCollection.horizontalSizeClass == .compact ? 999 : traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular ? 240 : constraint.priority
        }
        for constraint in regularConstraints {
            constraint.priority = traitCollection.horizontalSizeClass == .compact ? 240 : traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular ? 999 : constraint.priority
        }
        UIView.animate(withDuration: animationLength, animations: {
            self.view.layoutIfNeeded()
        })
    }
    
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context == &classContext,  let newValue = change?[NSKeyValueChangeKey.newKey] {
            if keyPath == "playerState" {
                let type: Trakt.MediaType = media is Movie ? .movies : .shows
                bufferView.dismiss()
                switch GCKMediaPlayerState(rawValue: newValue as! Int)! {
                case .paused:
                    UIApplication.shared.isIdleTimerDisabled = false
                    TraktManager.shared.scrobble(media.id, progress: progressSlider.value, type: type, status: .paused)
                    playPauseButton.setImage(UIImage(named: "Play"), for: .normal)
                    elapsedTimer.invalidate()
                    elapsedTimer = nil
                case .playing:
                    UIApplication.shared.isIdleTimerDisabled = true
                    TraktManager.shared.scrobble(media.id, progress: progressSlider.value, type: type, status: .watching)
                    playPauseButton.setImage(UIImage(named: "Pause"), for: .normal)
                    if elapsedTimer == nil {
                        elapsedTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateTime), userInfo: nil, repeats: true)
                    }
                case .buffering:
                    UIApplication.shared.isIdleTimerDisabled = true
                    playPauseButton.setImage(UIImage(named: "Play"), for: .normal)
                    bufferView.show(in: view)
                case .idle:
                    switch idleReason {
                    case .none:
                        break
                    default:
                        TraktManager.shared.scrobble(media.id, progress: progressSlider.value, type: type, status: .finished)
                        close()
                    }
                default:
                    break
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    func updateTime() {
        progressSlider.value = Float(streamPosition/streamDuration)
        remainingTimeLabel.text = remainingTime.stringValue
        elapsedTimeLabel.text = elapsedTime.stringValue
    }
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus) {
        if mediaStatus != nil // mediaStatus can be uninitialised when this delegate method is called even though it is not marked as an optional value. Stupid google-cast-sdk.
        {
            if !observingValues {
                if let subtitles = media.subtitles, let subtitle = media.currentSubtitle {
                    remoteMediaClient?.setActiveTrackIDs([NSNumber(value: subtitles.index{$0.link == subtitle.link}! as Int)])
                }
                elapsedTimer = elapsedTimer ?? Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateTime), userInfo: nil, repeats: true)
                mediaStatus.addObserver(self, forKeyPath: "playerState", options: .new, context: &classContext)
                observingValues = true
                streamPosition = startPosition * streamDuration
                self.volumeSlider?.setValue(mediaStatus.volume, animated: true)
            }
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        selectedSubtitleMeta = ["None", UserDefaults.standard.string(forKey: "PreferredSubtitleColor") ?? "White", UserDefaults.standard.string(forKey: "PreferredSubtitleFont") ?? "Default"]
        super.init(coder: aDecoder)
        remoteMediaClient?.add(self)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        //pickerView?.setNeedsLayout()
        //pickerView?.layoutIfNeeded()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let image = backgroundImage {
            imageView.image = image
            backgroundImageView.image = image
        } 
        titleLabel.text = title
        //pickerView = PCTPickerView(superView: view, componentDataSources: [subtitles as Dictionary<String, AnyObject>, subtitleColors, subtitleFonts], delegate: self, selectedItems: selectedSubtitleMeta, attributesForComponents: [nil, NSForegroundColorAttributeName, NSFontAttributeName])
        //view.addSubview(pickerView)
        bufferView.show(in: view)
        Timer.after(30.0) { [weak self] in
            if let weakSelf = self {
                if weakSelf.bufferView.isVisible && weakSelf.streamPosition == 0.0 {
                    weakSelf.bufferView.indicatorView = JGProgressHUDErrorIndicatorView()
                    weakSelf.bufferView.textLabel.text = "Error loading movie."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: {
                        weakSelf.close()
                    })
                }
            }            
        }
        volumeSlider?.setThumbImage(UIImage(named: "Scrubber Image"), for: .normal)
    }
    
//    func pickerView(_ pickerView: PCTPickerView, didClose items: [String : AnyObject]) {
//        selectedSubtitleMeta = Array(items.keys)
//        let trackStyle = GCKMediaTextTrackStyle.createDefault()
//        for (index, value) in items.values.enumerated() {
//            if let font = value as? UIFont {
//                trackStyle.fontFamily = font.familyName
//            } else if let color = value as? UIColor {
//                trackStyle.foregroundColor = GCKColor(uiColor: color)
//            } else if let link = value as? String {
//                if link != "None" {
//                    PopcornKit.downloadSubtitleFile(link, fileName: Locale.langs.allKeysForValue(Array(items.keys)[index]).first! + ".vtt", downloadDirectory: directory, convertToVTT: true, completion: { (_, error) in
//                        guard error == nil else { return }
//                        self.remoteMediaClient?.setActiveTrackIDs([NSNumber(value: index as Int)])
//                    })
//                } else {
//                    remoteMediaClient?.setActiveTrackIDs(nil)
//                }
//            }
//        }
//        remoteMediaClient?.setTextTrackStyle(trackStyle)
//    }
    
    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    override var shouldAutorotate : Bool {
        return UIDevice.current.userInterfaceIdiom == .pad
    }
    
    override var preferredStatusBarStyle : UIStatusBarStyle {
        return .lightContent
    }

}
