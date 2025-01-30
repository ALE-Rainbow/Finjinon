//
//  Copyright (c) 2017 FINN.no AS. All rights reserved.
//

import UIKit
import AVFoundation
import MobileCoreServices
import Photos

public let FinjinonCameraAccessErrorDomain = "FinjinonCameraAccessErrorDomain"
public let FinjinonCameraAccessErrorDeniedCode = 1
public let FinjinonCameraAccessErrorDeniedInitialRequestCode = 2
public let FinjinonLibraryAccessErrorDomain = "FinjinonLibraryAccessErrorDomain"

public protocol PhotoCaptureViewControllerDelegate: NSObjectProtocol {
    func photoCaptureViewControllerDidFinish(_ controller: PhotoCaptureViewController)
    func photoCaptureViewController(_ controller: PhotoCaptureViewController, didSelectAssetAtIndexPath indexPath: IndexPath)
    func photoCaptureViewController(_ controller: PhotoCaptureViewController, didFailWithError error: NSError)

    func photoCaptureViewController(_ controller: PhotoCaptureViewController, cellForItemAtIndexPath indexPath: IndexPath) -> PhotoCollectionViewCell?
    func photoCaptureViewController(_ controller: PhotoCaptureViewController, didMoveItemFromIndexPath fromIndexPath: IndexPath, toIndexPath: IndexPath)

    func photoCaptureViewControllerNumberOfAssets(_ controller: PhotoCaptureViewController) -> Int
    func photoCaptureViewController(_ controller: PhotoCaptureViewController, assetForIndexPath indexPath: IndexPath) -> Asset
    // delegate is responsible for updating own data structure to include new asset at the tip when one is added,
    // eg photoCaptureViewControllerNumberOfAssets should be +1 after didAddAsset is called
    func photoCaptureViewController(_ controller: PhotoCaptureViewController, didAddAsset asset: Asset)
    func photoCaptureViewController(_ controller: PhotoCaptureViewController, deleteAssetAtIndexPath indexPath: IndexPath)
    func photoCaptureViewController(_ controller: PhotoCaptureViewController, canMoveItemAtIndexPath indexPath: IndexPath) -> Bool
}

open class PhotoCaptureViewController: UIViewController, PhotoCollectionViewLayoutDelegate {
    open weak var delegate: PhotoCaptureViewControllerDelegate?
    /// Optional instance confirming to the ImagePickerAdapter-protocol to allow selecting an image from the library.
    /// The default implementation will present a UIImagePickerController. Setting this to nil, will remove the library-button.
    open var imagePickerAdapter: ImagePickerAdapter? = ImagePickerControllerAdapter() {
        didSet {
            updateImagePickerButton()
        }
    }

    /// Optional view to display when returning from imagePicker not finished retrieving data.
    /// Use constraints to position elements dynamically, as the view will be rotated and sized with the device.
    open var imagePickerWaitingForImageDataView: UIView?

    open var enableLowLightWarning = false
    
    open var closeButtonTitle : String? = "Cancel"
    
    open var doneButtonTitle : String? = "Done"
    
    fileprivate let storage = PhotoStorage()
    fileprivate let captureManager = CaptureManager()
    fileprivate var previewView = UIView()
    fileprivate var captureButton = TriggerButton()
    fileprivate let collectionView = UICollectionView(frame: CGRect.zero, collectionViewLayout: UICollectionViewFlowLayout())
    fileprivate var containerView = UIView()
    fileprivate var focusIndicatorView = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
    fileprivate var flashButton = UIButton()
    fileprivate var switchCameraButton = UIButton()
    fileprivate var doneButton = UIButton()
    fileprivate var pickerButton: UIButton?
    fileprivate var closeButton = UIButton()
    fileprivate let buttonMargin: CGFloat = 12
    fileprivate var overlayButtonConfiguration : UIButton.Configuration = .plain()
    fileprivate var overlayButtonSize : CGFloat = 40.0
    fileprivate let buttonAlignOffset : CGFloat = 4.0
    
    fileprivate var lensStackView = UIStackView()
    fileprivate let lensStackViewOffset: CGFloat = 16.0
    fileprivate var wideLensButton = UIButton()
    fileprivate var standardLensButton = UIButton()
    fileprivate var teleLensButton = UIButton()
    fileprivate var lensButtons: [UIButton] = []
    fileprivate var lensButtonConfiguration : UIButton.Configuration = .borderedTinted()
    
    fileprivate var emptyCollectionView = UIView(frame: CGRect(x: 15, y: 15, width: 148, height: 148))
    
    fileprivate var orientation: UIDeviceOrientation = .portrait

    private lazy var lowLightView: LowLightView = {
        let view = LowLightView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private var viewFrame = CGRect.zero
    private var viewBounds = CGRect.zero
    private var subviewSetupDone = false
    
    private var zoomBegin: CGFloat = 1.0
    private var panZoomSpeed: CGFloat = 5.0

    deinit {
        captureManager.stop(nil)
    }

    open override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.black
        
        if shouldAutorotate {
            OTC.log("Couldn't lock device orientation (iPad)")
        }
        
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil) { (_) -> Void in
            switch UIDevice.current.orientation {
            case .faceDown, .faceUp, .unknown:
                ()
            case .landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown:
                self.orientation = UIDevice.current.orientation
                self.updateWidgetsToOrientation()
            default:
                ()
            }
        }
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name.AVCaptureSessionWasInterrupted, object: nil, queue: nil) { (_) -> Void in
            OTC.log("AVCaptureSessionWasInterrupted")
            self.captureManager.stop(nil)
            self.dismiss(animated: true, completion: nil)
        }
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Setting subviews in viewDidAppear is not a great solution... It's a fix to respect Safe Areas (known after
        // viewDidAppear) for iPhone X in particular. Setting positions constrained to Safe Area would allow for more
        // flexibility with Auto Layout, and thus creating the subViews in viewDidLoad/viewWillAppear would be possible again.

        view.insetsLayoutMarginsFromSafeArea = true
        viewFrame = view.convert(view.safeAreaLayoutGuide.layoutFrame, to: view.superview ?? view)
        viewBounds = view.safeAreaLayoutGuide.layoutFrame

        setupSubviews()

        collectionView.reloadData()
        scrollToLastAddedAssetAnimated(false)
        
        captureManager.start(nil)
        
        // captureManager.previewLayer.connection take some time to be available the first time the camera is used
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.updateVideoOrientation()
        }
        
    }

    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        captureManager.stop(nil)
    }
    

    func setupSubviews() {
        // Subviews need to be added and framed during viewDidAppear for the iPhone X's safeAreas to be known.
        if subviewSetupDone { return }
        subviewSetupDone = true

        previewView.frame = viewBounds
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(previewView)
        let previewLayer = captureManager.previewLayer
        // We are using AVCaptureSessionPresetPhoto which has a 4:3 aspect ratio
        let viewFinderWidth = viewBounds.size.width
        var viewFinderHeight = (viewFinderWidth / 3) * 4
        if captureManager.viewfinderMode == .fullScreen {
            viewFinderHeight = viewBounds.size.height
        }
        previewLayer.frame = CGRect(x: 0, y: 0, width: viewFinderWidth, height: viewFinderHeight)
        previewView.layer.addSublayer(previewLayer)

        focusIndicatorView.backgroundColor = UIColor.clear
        focusIndicatorView.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicatorView.layer.borderWidth = 1.0
        focusIndicatorView.alpha = 0.0
        previewView.addSubview(focusIndicatorView)

        let tapper = UITapGestureRecognizer(target: self, action: #selector(focusTapGestureRecognized(_:)))
        previewView.addGestureRecognizer(tapper)

        let zoomGesture = UIPanGestureRecognizer(target: self, action: #selector(zoomGestureRecognized(_:)))
        previewView.addGestureRecognizer(zoomGesture)
        
        var collectionViewHeight: CGFloat = min(viewFrame.size.height / 6, 120)
        let window = UIApplication.keyWindow
        let collectionViewBottomMargin: CGFloat = 70 + (window?.safeAreaInsets.bottom ?? 0)
        let cameraButtonHeight: CGFloat = 66

        var containerFrame = CGRect(x: viewFrame.origin.x, y: viewFrame.origin.y + viewBounds.height - collectionViewBottomMargin - collectionViewHeight, width: viewBounds.width, height: collectionViewBottomMargin + collectionViewHeight)
        if captureManager.viewfinderMode == .window {
            let containerHeight = viewFrame.height - viewFinderHeight
            containerFrame.origin.y = viewFrame.origin.y + viewFrame.height - containerHeight
            containerFrame.size.height = containerHeight
            collectionViewHeight = containerHeight - cameraButtonHeight
        }
        containerView.frame = containerFrame
        containerView.backgroundColor = UIColor(white: 0, alpha: 0.2)
        containerView.alpha = 0.75
        view.addSubview(containerView)
        collectionView.frame = CGRect(x: 0, y: 0, width: containerView.bounds.width, height: collectionViewHeight)
        let layout = PhotoCollectionViewLayout()
        layout.delegate = self
        collectionView.collectionViewLayout = layout

        layout.scrollDirection = .horizontal
        let inset: CGFloat = 8
        layout.itemSize = CGSize(width: collectionView.frame.height - (inset * 2), height: collectionView.frame.height - (inset * 2))
        layout.sectionInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        layout.minimumInteritemSpacing = inset
        layout.minimumLineSpacing = inset
        layout.didReorderHandler = { [weak self] fromIndexPath, toIndexPath in
            if let welf = self {
                welf.delegate?.photoCaptureViewController(welf, didMoveItemFromIndexPath: fromIndexPath as IndexPath, toIndexPath: toIndexPath as IndexPath)
            }
        }

        collectionView.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        collectionView.alwaysBounceHorizontal = true
        containerView.addSubview(collectionView)
        
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4).isActive = true
        collectionView.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: 0).isActive = true
        collectionView.rightAnchor.constraint(equalTo: containerView.rightAnchor, constant: 0).isActive = true
        collectionView.heightAnchor.constraint(equalToConstant: collectionViewHeight).isActive = true
        
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0).isActive = true
        containerView.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 0).isActive = true
        containerView.rightAnchor.constraint(equalTo: view.rightAnchor, constant: 0).isActive = true
        containerView.heightAnchor.constraint(equalToConstant: collectionViewBottomMargin + collectionViewHeight).isActive = true

        collectionView.register(PhotoCollectionViewCell.self, forCellWithReuseIdentifier: PhotoCollectionViewCell.cellIdentifier())
        collectionView.dataSource = self
        collectionView.delegate = self
        
        setupEmptyCollectionView()
        collectionView.addSubview(emptyCollectionView)
        
        // Overlay buttons
        
        overlayButtonConfiguration.buttonSize = .large
        overlayButtonConfiguration.baseBackgroundColor = UIColor(white: 0.3, alpha: 0.7)
        overlayButtonConfiguration.cornerStyle = .capsule
        
        let flashButtonFrame = CGRect(x: buttonMargin, y: viewFrame.origin.y + buttonMargin, width: overlayButtonSize, height: overlayButtonSize)
        let flashImage = UIImage(systemName: "bolt.slash.circle")
        setupOverlayButton(flashButton, image: flashImage, frame: flashButtonFrame, action: #selector(flashButtonTapped(_:)))
        
        let switchCameraButtonFrame = CGRect(x: viewFrame.width - overlayButtonSize - buttonMargin, y: viewFrame.origin.y + buttonMargin, width: overlayButtonSize, height: overlayButtonSize)
        let switchCameraImage = UIImage(systemName: "arrow.trianglehead.2.clockwise.rotate.90.camera")
        setupOverlayButton(switchCameraButton, image: switchCameraImage, frame: switchCameraButtonFrame, action: #selector(switchCameraButtonTapped(_:)))
        
        // Action buttons
        
        captureButton.frame = CGRect(x: (containerView.frame.width / 2) - cameraButtonHeight / 2, y: containerView.frame.height - cameraButtonHeight - 12, width: cameraButtonHeight, height: cameraButtonHeight)
        captureButton.layer.cornerRadius = cameraButtonHeight / 2
        captureButton.addTarget(self, action: #selector(capturePhotoTapped(_:)), for: .touchUpInside)
        containerView.addSubview(captureButton)
        
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.topAnchor.constraint(equalTo: collectionView.bottomAnchor, constant: 0).isActive = true
        captureButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor).isActive = true
        captureButton.widthAnchor.constraint(equalToConstant: cameraButtonHeight).isActive = true
        captureButton.heightAnchor.constraint(equalToConstant: cameraButtonHeight).isActive = true
        
        captureButton.isEnabled = false
        captureButton.accessibilityLabel = "finjinon.captureButton".localized()

        let doneButtonSize : CGFloat = 30
        doneButton.frame = CGRect(x: viewFrame.width - doneButtonSize - buttonMargin, y: doneButton.frame.midY - doneButtonSize/2, width: doneButtonSize, height: doneButtonSize)
        doneButton.setTitle(doneButtonTitle, for: .normal)
        doneButton.addTarget(self, action: #selector(doneButtonTapped(_:)), for: .touchUpInside)
        doneButton.tintColor = UIColor.white
        doneButton.sizeToFit()
        doneButton.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        containerView.addSubview(self.doneButton)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.rightAnchor.constraint(equalTo: self.view.rightAnchor, constant: -buttonMargin).isActive = true
        doneButton.centerYAnchor.constraint(equalTo: self.captureButton.centerYAnchor).isActive = true
        doneButton.isHidden = true

        let closeButtonSize : CGFloat = 30
        closeButton.frame = CGRect(x: viewFrame.origin.x + buttonMargin, y: doneButton.frame.midY - closeButtonSize/2, width: closeButtonSize, height: closeButtonSize)
        closeButton.addTarget(self, action: #selector(closeButtonTapped(_:)), for: .touchUpInside)
        closeButton.setTitle(closeButtonTitle, for: .normal)
        closeButton.tintColor = UIColor.white
        closeButton.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        closeButton.sizeToFit()
        containerView.addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.leftAnchor.constraint(equalTo: self.view.leftAnchor, constant: buttonMargin).isActive = true
        closeButton.centerYAnchor.constraint(equalTo: self.captureButton.centerYAnchor).isActive = true
      
        if enableLowLightWarning {
            view.addSubview(lowLightView)
            NSLayoutConstraint.activate([
                lowLightView.bottomAnchor.constraint(equalTo: collectionView.topAnchor, constant: -16),
                lowLightView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                lowLightView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8)
            ])
        }

        updateImagePickerButton()

        setupCaptureManager()
    }
    
    /// Setup the view that is displayed when there is no taken photo in the collection view
    private func setupEmptyCollectionView() {
        let emptyCollectionViewBorder = CAShapeLayer()
        emptyCollectionViewBorder.strokeColor = UIColor.white.cgColor
        emptyCollectionViewBorder.lineWidth = 1.5
        emptyCollectionViewBorder.lineJoin = CAShapeLayerLineJoin.round
        emptyCollectionViewBorder.lineDashPattern = [6, 6]
        emptyCollectionViewBorder.frame = emptyCollectionView.bounds
        emptyCollectionViewBorder.fillColor = nil
        emptyCollectionViewBorder.path = UIBezierPath(roundedRect: emptyCollectionView.bounds, cornerRadius: 24).cgPath
        emptyCollectionView.layer.addSublayer(emptyCollectionViewBorder)
    }
    
    /// Determine the number of physical lens then configure the relevant switch lens buttons
    private func setupLenses() {
        //let insetValue = 2.0
        //lensButtonConfiguration.contentInsets = NSDirectionalEdgeInsets(top: insetValue, leading: insetValue, bottom: insetValue, trailing: insetValue)
        lensButtonConfiguration.baseBackgroundColor = UIColor(white: 0.3, alpha: 0.7)
        //lensButtonConfiguration.buttonSize = .mini
        lensButtonConfiguration.cornerStyle = .capsule
        
        if captureManager.zoomFactors.count > 0 {
            let titles = lensTitles()
            
            if captureManager.zoomFactors.count == 1 {
                setupLensButton(wideLensButton, camera:.ultraWide, title: titles[0])
                setupLensButton(standardLensButton, camera: .wide, title: titles[1], isSelected: true)
                lensButtons = [wideLensButton, standardLensButton]
                
            } else if captureManager.zoomFactors.count == 2 {
                
                setupLensButton(wideLensButton, camera:.ultraWide, title: titles[0])
                setupLensButton(standardLensButton, camera: .wide, title: titles[1], isSelected: true)
                setupLensButton(teleLensButton, camera: .telephoto, title: titles[2])
                lensButtons = [wideLensButton, standardLensButton, teleLensButton]
            }
        }
    }
    
    /// Returns the titles of the physical lenses
    /// - Returns: the titles array ordered from wide to tele angle
    private func lensTitles() -> [String] {
        var titles: [String] = []
        
        if captureManager.zoomFactors.count > 0 {
            titles.append("0.5")
            captureManager.zoomFactors.forEach(){
                titles.append(String(format: "%0.1f", CGFloat(truncating: $0) / 2.0))
            }
            
        // There is only one physical lens
        } else {
            titles.append("1.0")
        }
        
        return titles
    }
    
    /// Setup the button dedicate to switch the virtual camera to a physical camera angle
    /// - Parameters:
    ///   - button: the button to setup
    ///   - camera: the `PhysicalCameraAngle` of the physical camera
    ///   - title: the label (zoom multiplier)
    ///   - isSelected: `true` if this physical camera is selected
    private func setupLensButton(_ button: UIButton, camera: PhysicalCameraAngle, title: String, isSelected: Bool = false) {
        button.isSelected = isSelected
        let attrTitle = NSAttributedString(string: title, attributes: [ NSAttributedString.Key.foregroundColor: UIColor.white, NSAttributedString.Key.font: UIFont.systemFont(ofSize: 11, weight: .bold)])
        button.setAttributedTitle(attrTitle, for: .normal)
        let attrSelectedTitle = NSAttributedString(string: title, attributes: [ NSAttributedString.Key.foregroundColor: UIColor.systemYellow, NSAttributedString.Key.font: UIFont.systemFont(ofSize: 11, weight: .bold)])
        button.setAttributedTitle(attrSelectedTitle, for: .selected)
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(.systemYellow, for: .selected)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalTo: button.heightAnchor, constant: 0).isActive = true
        //button.heightAnchor.constraint(equalToConstant: isSelected ? 32 : 24).isActive = true
        button.addTarget(self, action: #selector(handleLensButtonTapped(_:)), for: .touchUpInside)
        button.tag = camera.rawValue
        button.configuration = lensButtonConfiguration
        /*
        button.configurationUpdateHandler = { button in
            var config = button.configuration
            switch button.state {
            case .selected, .highlighted:
                config?.buttonSize = .medium
                //let insetValue = 16.0
                //config?.contentInsets = NSDirectionalEdgeInsets(top: insetValue, leading: insetValue, bottom: insetValue, trailing: insetValue)
            default:
                config?.buttonSize = .mini
                //let insetValue = 8.0
                //config?.contentInsets = NSDirectionalEdgeInsets(top: insetValue, leading: insetValue, bottom: insetValue, trailing: insetValue)
            }
            button.configuration = config
        }
        button.updateConfiguration()*/
    }
    
    /// Action handler called when a camera button is tapped
    /// - Parameter button: the camera button
    @objc func handleLensButtonTapped(_ button: UIButton) {
        lensButtons.forEach{ $0.isSelected = $0 == button ? true : false }
        let cameraAngle = PhysicalCameraAngle(rawValue: button.tag) ?? .wide
        captureManager.switchToPhysicalCamera(angle: cameraAngle, animated: true)
    }
    
    /// Setup an overlay button such as the flash or front/back camera switches
    /// - Parameters:
    ///   - button: the button
    ///   - image: the button's image
    ///   - frame: the button's frame
    ///   - action: the action handler when the button is touched
    private func setupOverlayButton(_ button: UIButton, image: UIImage?, frame: CGRect, action: Selector) {
        button.frame = frame
        button.setImage(image, for: .normal)
        button.configuration = overlayButtonConfiguration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.tintColor = UIColor.white
        button.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }
    
    /// - Returns: The index of the selected lens button
    private func selectedLensIndex() -> Int? {
        return lensButtons.firstIndex(where: {$0.isSelected })
    }
    
    private func setupCaptureManager() {
        previewView.alpha = 0.0
        captureManager.prepare { error in
            if let error = error {
                self.delegate?.photoCaptureViewController(self, didFailWithError: error)
                return
            }
            
            self.setupCameraSelector()
            
            if self.captureManager.hasFlash {
                self.view.addSubview(self.flashButton)
            }
            
            if self.captureManager.hasFrontCamera {
                self.view.addSubview(self.switchCameraButton)
            }
            
            UIView.animate(withDuration: 0.2, animations: {
                self.captureButton.isEnabled = true
                self.previewView.alpha = 1.0
            })
        }

        captureManager.delegate = self
    }
    
    /// Setup the camera button container
    private func setupCameraSelector() {
        if captureManager.zoomFactors.count > 0 {
            previewView.addSubview(lensStackView)
            lensStackView.axis = .horizontal
            lensStackView.alignment = .center
            lensStackView.distribution = .fillEqually
            lensStackView.spacing = 10
            lensStackView.backgroundColor = UIColor(white: 0.3, alpha: 0.3)
            lensStackView.layer.cornerRadius = 30
            lensStackView.layer.masksToBounds = true
            lensStackView.isLayoutMarginsRelativeArrangement = true
            lensStackView.layoutMargins = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
            lensStackView.translatesAutoresizingMaskIntoConstraints = false
            lensStackView.bottomAnchor.constraint(equalTo: containerView.topAnchor, constant: -lensStackViewOffset).isActive = true
            lensStackView.centerXAnchor.constraint(equalTo: previewView.centerXAnchor).isActive = true
            lensStackView.heightAnchor.constraint(equalToConstant: 60).isActive = true
            lensStackView.widthAnchor.constraint(equalToConstant: CGFloat((1 + captureManager.zoomFactors.count) * 60)).isActive = true
            
            setupLenses()
            lensButtons.forEach {
                lensStackView.addArrangedSubview($0)
            }
        }
    }

    private func updateImagePickerButton() {
        if imagePickerAdapter == nil {
            if pickerButton != nil {
                pickerButton?.removeFromSuperview()
                pickerButton = nil
            }
        } else {
            let pickerButtonWidth: CGFloat = 114
            let pickerButtonHeight : CGFloat = 38
            let buttonRect = CGRect(x: (containerView.frame.width - pickerButtonWidth)/2, y: lensStackViewOffset, width: pickerButtonWidth, height: pickerButtonHeight)

            if pickerButton == nil {
                pickerButton = UIButton(frame: buttonRect)
                if let pickerButton {
                    pickerButton.setTitle("finjinon.photos".localized(), for: .normal)
                    let icon = UIImage(named: "PhotosIcon", in: Bundle(for: PhotoCaptureViewController.self), compatibleWith: nil)
                    pickerButton.setImage(icon, for: .normal)
                    pickerButton.addTarget(self, action: #selector(presentImagePickerTapped(_:)), for: .touchUpInside)
                    pickerButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
                    pickerButton.autoresizingMask = [.flexibleTopMargin]
                    pickerButton.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                    roundifyButton(pickerButton)
                    previewView.addSubview(pickerButton)
                }
            } else {
                pickerButton!.frame = buttonRect
            }
            view.bringSubviewToFront(pickerButton!)
        }
    }

    open override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }

    open override var prefersStatusBarHidden: Bool {
        return true
    }

    open override var shouldAutorotate: Bool {
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    open override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if shouldAutorotate {
            return .all
        } else {
            return .portrait
        }
    }

    // MARK: - API

    open func registerClass(_ cellClass: AnyClass?, forCellWithReuseIdentifier identifier: String) {
        collectionView.register(cellClass, forCellWithReuseIdentifier: identifier)
    }

    open func dequeuedReusableCellForClass<T: PhotoCollectionViewCell>(_ clazz: T.Type, indexPath: IndexPath, config: ((T) -> Void)) -> T {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: clazz.cellIdentifier(), for: indexPath) as! T
        config(cell)
        return cell
    }

    open func reloadPreviewItemsAtIndexes(_ indexes: [Int]) {
        let indexPaths = indexes.map { IndexPath(item: $0, section: 0) }
        collectionView.reloadItems(at: indexPaths)
    }

    open func reloadPreviews() {
        collectionView.reloadData()
    }

    open func selectedPreviewIndexPath() -> IndexPath? {
        if let selection = collectionView.indexPathsForSelectedItems {
            return selection.first
        }

        return nil
    }

    open func cellForpreviewAtIndexPath<T: PhotoCollectionViewCell>(_ indexPath: IndexPath) -> T? {
        return collectionView.cellForItem(at: indexPath) as? T
    }

    /// returns the rect in view (minus the scroll offset) of the thumbnail at the given indexPath.
    /// Useful for presenting sheets etc from the thumbnail
    open func previewRectForIndexPath(_ indexPath: IndexPath) -> CGRect {
        if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
            var rect = attributes.frame
            rect.origin.x -= collectionView.contentOffset.x
            rect.origin.y -= collectionView.contentOffset.y
            return view.convert(rect, from: collectionView.superview)
        }
        return CGRect.zero
    }

    open func createAssetFromImageData(_ data: Data, completion: @escaping (Asset) -> Void) {
        storage.createAssetFromImageData(data, completion: completion)
    }

    open func createAssetFromImage(_ image: UIImage, completion: @escaping (Asset) -> Void) {
        storage.createAssetFromImage(image, completion: completion)
    }

    open func createAssetFromImageURL(_ imageURL: URL, dimensions: CGSize, completion: @escaping (Asset) -> Void) {
        storage.createAssetFromImageURL(imageURL, dimensions: dimensions, completion: completion)
    }

    /// Deletes item at the given index. Perform any deletions from datamodel in the handler
    open func deleteAssetAtIndex(_ idx: Int, handler: @escaping () -> Void) {
        let indexPath = IndexPath(item: idx, section: 0)
        if let asset = delegate?.photoCaptureViewController(self, assetForIndexPath: indexPath) {
            collectionView.performBatchUpdates({
                handler()
                self.collectionView.deleteItems(at: [indexPath])
            }, completion: { _ in
                if asset.imageURL == nil {
                    self.storage.deleteAsset(asset, completion: {})
                }
            })
        }
    }

    open func libraryAuthorizationStatus() -> PHAuthorizationStatus {
        return PHPhotoLibrary.authorizationStatus()
    }

    open func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        return captureManager.authorizationStatus()
    }

    // MARK: - Actions

    @objc func flashButtonTapped(_: UIButton) {
        let mode = captureManager.nextAvailableFlashMode() ?? .off
        var icon : UIImage?
        var tintColor : UIColor?
        captureManager.changeFlashMode(mode) {
            switch mode {
            case .off:
                icon = UIImage(systemName: "bolt.slash.circle")
                tintColor = .white
            case .on:
                icon = UIImage(systemName: "bolt.circle.fill")
                tintColor = .systemYellow
            case .auto:
                icon = UIImage(systemName: "bolt.circle")
                tintColor = .white
            default:
                icon = nil
            }
            if let icon {
                self.flashButton.setImage(icon, for: .normal)
            }
            if let tintColor {
                self.flashButton.tintColor = tintColor
            }
        }
    }

    
    @objc func switchCameraButtonTapped(_: UIButton) {
        captureManager.switchCameraPosition { error in
            guard error == nil else {
                return
            }
            
            self.lensStackView.isHidden =  self.captureManager.cameraPosition == .front ? true : false
            if !self.lensStackView.isHidden {
                self.updateSelectedLensButton(forZoomFactor: 2.0)
            }
            
            if self.captureManager.hasFlash {
                if self.flashButton.isDescendant(of: self.view) == false {
                    self.view.addSubview(self.flashButton)
                }
            } else  {
                self.flashButton.removeFromSuperview()
            }
        }
    }

    @objc func presentImagePickerTapped(_: AnyObject) {
        if libraryAuthorizationStatus() == .denied || libraryAuthorizationStatus() == .restricted {
            let error = NSError(domain: FinjinonLibraryAccessErrorDomain, code: 0, userInfo: nil)
            delegate?.photoCaptureViewController(self, didFailWithError: error)
            return
        }

        guard let controller = imagePickerAdapter?.viewControllerForImageSelection({ assets in
            if let waitView = self.imagePickerWaitingForImageDataView, assets.count > 0 {
                waitView.translatesAutoresizingMaskIntoConstraints = false
                self.view.addSubview(waitView)

                waitView.removeConstraints(waitView.constraints.filter({ (constraint: NSLayoutConstraint) -> Bool in
                    constraint.secondItem as? UIView == self.view
                }))
                self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .centerX, relatedBy: .equal, toItem: self.view, attribute: .centerX, multiplier: 1, constant: 0))
                self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .centerY, relatedBy: .equal, toItem: self.view, attribute: .centerY, multiplier: 1, constant: 0))

                switch UIDevice.current.orientation {
                case .landscapeRight:
                    self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .height, relatedBy: .equal, toItem: self.view, attribute: .width, multiplier: 1, constant: 0))
                    self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .width, relatedBy: .equal, toItem: self.view, attribute: .height, multiplier: 1, constant: 0))

                case .landscapeLeft:
                    self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .height, relatedBy: .equal, toItem: self.view, attribute: .width, multiplier: 1, constant: 0))
                    self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .width, relatedBy: .equal, toItem: self.view, attribute: .height, multiplier: 1, constant: 0))

                default:
                    self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .height, relatedBy: .equal, toItem: self.view, attribute: .height, multiplier: 1, constant: 0))
                    self.view.addConstraint(NSLayoutConstraint(item: waitView, attribute: .width, relatedBy: .equal, toItem: self.view, attribute: .width, multiplier: 1, constant: 0))
                }
                if !self.shouldAutorotate {
                    waitView.rotateToCurrentDeviceOrientation()
                }
            }

            let resolver = AssetResolver()
            var count = assets.count
            assets.forEach { asset in
                resolver.enqueueResolve(asset, completion: { image in
                    self.createAssetFromImage(image, completion: { (asset: Asset) in
                        var mutableAsset = asset
                        mutableAsset.imageDataSourceType = .library
                        self.didAddAsset(mutableAsset)

                        count -= 1
                        if count == 0 {
                            self.imagePickerWaitingForImageDataView?.removeFromSuperview()
                        }
                    })
                })
            }
        }, completion: { _ in
            DispatchQueue.main.async {
                self.dismiss(animated: true, completion: nil)
            }
        }) else {
            return
        }

        present(controller, animated: true, completion: nil)
    }

    @objc func capturePhotoTapped(_ sender: UIButton) {
        sender.isEnabled = false
        UIView.animate(withDuration: 0.1, animations: { self.previewView.alpha = 0.0 }, completion: { _ in
            UIView.animate(withDuration: 0.1, animations: { self.previewView.alpha = 1.0 })
        })

        captureManager.captureImage()
    }

    fileprivate func didAddAsset(_ asset: Asset) {
        DispatchQueue.main.async {
            self.collectionView.performBatchUpdates({
                self.delegate?.photoCaptureViewController(self, didAddAsset: asset)
                let insertedIndexPath: IndexPath
                if let count = self.delegate?.photoCaptureViewControllerNumberOfAssets(self) {
                    insertedIndexPath = IndexPath(item: count - 1, section: 0)
                } else {
                    insertedIndexPath = IndexPath(item: 0, section: 0)
                }
                self.collectionView.insertItems(at: [insertedIndexPath])
            }, completion: { _ in
                self.scrollToLastAddedAssetAnimated(true)
                if self.collectionView.numberOfItems(inSection: 0) > 0 {
                    self.doneButton.isHidden = false
                }
            })
        }
    }

    fileprivate func scrollToLastAddedAssetAnimated(_ animated: Bool) {
        if let count = self.delegate?.photoCaptureViewControllerNumberOfAssets(self), count > 0 {
            collectionView.scrollToItem(at: IndexPath(item: count - 1, section: 0), at: .left, animated: animated)
        }
    }

    @objc func closeButtonTapped(_: UIButton) {
        dismiss(animated: true, completion: nil)
    }
    
    @objc func doneButtonTapped(_: UIButton) {
        delegate?.photoCaptureViewControllerDidFinish(self)

        dismiss(animated: true, completion: nil)
    }

    @objc func focusTapGestureRecognized(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .ended {
            let point = gestureRecognizer.location(in: gestureRecognizer.view)

            focusIndicatorView.center = point
            UIView.animate(withDuration: 0.3, delay: 0.0, options: .beginFromCurrentState, animations: {
                self.focusIndicatorView.alpha = 1.0
            }, completion: { _ in
                UIView.animate(withDuration: 0.2, delay: 1.6, options: .beginFromCurrentState, animations: {
                    self.focusIndicatorView.alpha = 0.0
                }, completion: nil)
            })

            captureManager.lockFocusAtPointOfInterest(point)
        }
    }
    
    private var zoomTouchPoint : CGPoint = .zero
    @objc func zoomGestureRecognized(_ gestureRecognizer: UIPanGestureRecognizer) {
        switch gestureRecognizer.state {
        case .began:
            zoomBegin = captureManager.zoomFactor
            zoomTouchPoint = gestureRecognizer.location(in: view)
            
        case .changed:
            // horizontal distance from the initial touch point multiplied by the zoom speed
            let deltaX = (gestureRecognizer.location(in: view).x - zoomTouchPoint.x) * panZoomSpeed
            var zoomTo : CGFloat = zoomBegin + (deltaX / view.frame.width)
            // step 0.01 between 1.0 and zoomMax
            let msc = Int((zoomTo+0.001)*100) % 100
            zoomTo = trunc(zoomTo) + CGFloat(msc) * 0.01
            zoomTo = max(1, min(zoomTo, captureManager.maxZoomFactor))
            if captureManager.zoomFactor != zoomTo {
                captureManager.setZoomFactor(zoomTo)
                updateSelectedLensButton(forZoomFactor: zoomTo)
            }
            
        default:
            break
        }
    }
    
    /// Select the lens button matching the given zoomFactor
    /// - Parameter zoomFactor: the current zoom factor
    private func updateSelectedLensButton(forZoomFactor zoomFactor: CGFloat) {
        // If no lens is selected (-1) the following code will set one
        let selectedIndex = selectedLensIndex() ?? -1
        // Search the hardware lens index matching the current zoomFactor
        let newIndex = 1 + (captureManager.zoomFactors.lastIndex(where: { zoomFactor >= CGFloat(truncating: $0) }) ?? -1)
        if selectedIndex != newIndex {
            for(i, button) in lensButtons.enumerated() {
                button.isSelected = i == newIndex
            }
        }
    }

    // MARK: - PhotoCollectionViewLayoutDelegate

    open func photoCollectionViewLayout(_: UICollectionViewLayout, canMoveItemAtIndexPath indexPath: IndexPath) -> Bool {
        return delegate?.photoCaptureViewController(self, canMoveItemAtIndexPath: indexPath) ?? true
    }

    // MARK: - Video preview rotation
        
    func updateVideoOrientation() {
        let previewLayer = captureManager.previewLayer
        
        guard let connection = previewLayer.connection else {
            OTC.log("previewLayer.connection is nil")
            return
        }
        
        guard connection.isVideoOrientationSupported else {
            OTC.log("isVideoOrientationSupported is false")
            return
        }
        
        let statusBarOrientation : UIInterfaceOrientation?
        if let windowScene = UIApplication.mainScene {
            statusBarOrientation = windowScene.interfaceOrientation
        } else {
            statusBarOrientation = nil
        }
        
        let videoOrientation: AVCaptureVideoOrientation = statusBarOrientation?.videoOrientation ?? .portrait
        previewLayer.connection?.videoOrientation = videoOrientation
        previewLayer.removeAllAnimations()
    }
    
    open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        coordinator.animate(alongsideTransition: nil, completion: { [weak self] (context) in
            DispatchQueue.main.async(execute: {
                self?.updateVideoOrientation()
            })
        })
        
    }
        
    // MARK: - Private methods

    fileprivate func roundifyButton(_ button: UIButton, inset: CGFloat = 16) {
        button.tintColor = UIColor.white

        button.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        button.layer.borderColor = button.tintColor!.cgColor
        button.layer.borderWidth = 1.0
        button.layer.cornerRadius = button.bounds.height / 2

        var insets = button.imageEdgeInsets
        insets.left -= inset
        button.imageEdgeInsets = insets
    }

    fileprivate func updateWidgetsToOrientation() {
        if shouldAutorotate {
            return
        }
        var pickerPosition: CGPoint = pickerButton?.frame.origin ?? .zero
        if orientation == .landscapeLeft || orientation == .landscapeRight, let pickerButton {
            pickerPosition = CGPoint(x: (containerView.frame.width - pickerButton.bounds.size.width)/2, y: lensStackViewOffset)
        } else if orientation == .portrait || orientation == .portraitUpsideDown, let pickerButton {
            pickerPosition = CGPoint(x: (containerView.frame.height - pickerButton.bounds.size.width)/2, y: lensStackViewOffset)
        }
        let animations = {
            self.pickerButton?.rotateToCurrentDeviceOrientation()
            self.pickerButton?.frame.origin = pickerPosition
            self.flashButton.rotateToCurrentDeviceOrientation()
            self.closeButton.rotateToCurrentDeviceOrientation()
            self.switchCameraButton.rotateToCurrentDeviceOrientation()
            self.doneButton.rotateToCurrentDeviceOrientation()
            for button in self.lensButtons {
                button.rotateToCurrentDeviceOrientation()
            }
            for cell in self.collectionView.visibleCells {
                cell.contentView.rotateToCurrentDeviceOrientation()
            }
        }
        UIView.animate(withDuration: 0.25, animations: animations)
    }
}

extension PhotoCaptureViewController: UICollectionViewDataSource, PhotoCollectionViewCellDelegate {
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection _: Int) -> Int {
        if let count = delegate?.photoCaptureViewControllerNumberOfAssets(self), count > 0 {
            emptyCollectionView.isHidden = true
            collectionView.isScrollEnabled = true
            return count
        } else {
            emptyCollectionView.isHidden = false
            collectionView.isScrollEnabled = false
            return 0
        }
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell: PhotoCollectionViewCell
        if let delegateCell = delegate?.photoCaptureViewController(self, cellForItemAtIndexPath: indexPath) {
            cell = delegateCell
        } else {
            cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCollectionViewCell.cellIdentifier(), for: indexPath) as! PhotoCollectionViewCell
        }
        if !shouldAutorotate {
            // This cannot use the currentRotation call as it might be called when .FaceUp or .FaceDown is device-orientation
            cell.contentView.rotateToDeviceOrientation(orientation)
        }
        cell.delegate = self
        
        return cell
    }

    func collectionViewCellDidTapDelete(_ cell: PhotoCollectionViewCell) {
        if let indexPath = collectionView.indexPath(for: cell) {
            deleteAssetAtIndex(indexPath.item, handler: {
                self.delegate?.photoCaptureViewController(self, deleteAssetAtIndexPath: indexPath)
            })
        }
        
        if self.collectionView.numberOfItems(inSection: 0) == 0 {
            self.doneButton.isHidden = true
        }
    }
}

extension PhotoCaptureViewController: UICollectionViewDelegate {
    public func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        delegate?.photoCaptureViewController(self, didSelectAssetAtIndexPath: indexPath)
    }
}

extension PhotoCaptureViewController: CaptureManagerDelegate {
    func captureManager(_ manager: CaptureManager, didCaptureImageData data: Data?, withMetadata metadata: NSDictionary?) {
        guard let data = data else { return }

        captureButton.isEnabled = true

        createAssetFromImageData(data as Data, completion: { [weak self] (asset: Asset) in
            guard let self = self else { return }
            var mutableAsset = asset
            mutableAsset.imageDataSourceType = .camera
            self.didAddAsset(mutableAsset)
        })
    }

    func captureManager(_ manager: CaptureManager, didDetectLightingCondition lightingCondition: LightingCondition) {
        if !enableLowLightWarning {
            return
        }
        if lightingCondition == .low {
            lowLightView.text = "finjinon.lowLightMessage".localized()
            lowLightView.isHidden = false
        } else {
            lowLightView.text = nil
            lowLightView.isHidden = true
        }
    }
    
    func captureManager(_ manager: CaptureManager, didFailWithError error: NSError) {
        OTC.log("Failure: \(error)")
    }
}

extension UIView {
    public func rotateToCurrentDeviceOrientation() {
        rotateToDeviceOrientation(UIDevice.current.orientation)
    }

    public func rotateToDeviceOrientation(_ orientation: UIDeviceOrientation) {
        switch orientation {
        case .faceDown, .faceUp, .unknown:
            ()
        case .landscapeLeft:
            transform = CGAffineTransform(rotationAngle: CGFloat(Double.pi / 2))
        case .landscapeRight:
            transform = CGAffineTransform(rotationAngle: CGFloat(-Double.pi / 2))
        case .portrait, .portraitUpsideDown:
            transform = CGAffineTransform(rotationAngle: 0)
        @unknown default:
            return
        }
    }
}

// MARK: - UIInterfaceOrientation extension for video orientation

extension UIInterfaceOrientation {
    var videoOrientation: AVCaptureVideoOrientation? {
        switch self {
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        case .portrait: return .portrait
        default: return nil
        }
    }
}


