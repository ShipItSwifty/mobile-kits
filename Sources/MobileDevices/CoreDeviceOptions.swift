import DeviceCtlKit

// The option types of `PhysicalIOSDeviceManager`'s operations are the typed `devicectl` wrapper's,
// re-exported under CoreDevice names so a caller builds a request without importing `DeviceCtlKit`.

/// Table options: extra columns, hidden default columns and headers.
public typealias CoreDeviceColumnOptions = DeviceCtlColumnOptions
/// Row filtering: `--search`, an NSPredicate `--filter`, `--sort-by`, and columns.
public typealias CoreDeviceFilterOptions = DeviceCtlFilterOptions

/// A file service domain on a device (an app container, a temporary directory, crash logs).
public typealias CoreDeviceFileDomain = DeviceCtlFileDomain
/// The user and directory-replacement options of a file copy.
public typealias CoreDeviceCopyOptions = DeviceCtlCopyOptions

/// The filters of an app listing.
public typealias CoreDeviceAppListOptions = DeviceCtlAppListOptions
/// User, working directory, architecture, activation, and display of a launch.
public typealias CoreDeviceLaunchOptions = DeviceCtlLaunchOptions
/// Activation, termination, and display options of opening a URL.
public typealias CoreDeviceOpenURLOptions = DeviceCtlOpenURLOptions

/// A screen recording codec.
public typealias CoreDeviceCaptureCodec = DeviceCtlCaptureCodec
/// How a screen recording treats the device bezel.
public typealias CoreDeviceMaskPolicy = DeviceCtlMaskPolicy

/// The user interface style: light or dark.
public typealias CoreDeviceAppearanceMode = DeviceCtlAppearance
/// The Liquid Glass look: clear or tinted.
public typealias CoreDeviceLookAndFeel = DeviceCtlLookAndFeel
/// A text size, including the accessibility sizes.
public typealias CoreDeviceTextSize = DeviceCtlTextSize
/// A colour filter type.
public typealias CoreDeviceColorFilterType = DeviceCtlColorFilterType
/// Everything the appearance setting can change; `nil` fields are left alone.
public typealias CoreDeviceAppearanceSettings = DeviceCtlAppearanceSettings

/// Query, enable, or disable biometric enrolment.
public typealias CoreDeviceBiometricsAction = DeviceCtlBiometricsAction
/// A simulated biometric match or failure.
public typealias CoreDeviceBiometricOutcome = DeviceCtlBiometricOutcome
/// Show or hide StandBy.
public typealias CoreDeviceStandbyAction = DeviceCtlStandbyAction
/// A device orientation.
public typealias CoreDeviceOrientation = DeviceCtlOrientation
/// A relative rotation.
public typealias CoreDeviceRotationDirection = DeviceCtlRotationDirection
/// A full or userspace reboot.
public typealias CoreDeviceRebootStyle = DeviceCtlRebootStyle

/// A simulated route of waypoints, or a route file.
public typealias CoreDeviceLocationRoute = DeviceCtlLocationRoute
/// The indicators a status bar override can set.
public typealias CoreDeviceStatusBarOverride = DeviceCtlStatusBarOverride
/// A named status bar configuration.
public typealias CoreDeviceStatusBarPreset = DeviceCtlStatusBarPreset

/// How pasteboard data crosses between host and device.
public typealias CoreDevicePasteboardDataPolicy = DeviceCtlPasteboardDataPolicy
/// The options of a one-way pasteboard transfer.
public typealias CoreDevicePasteboardTransfer = DeviceCtlPasteboardTransfer
/// The options of a two-way pasteboard sync.
public typealias CoreDevicePasteboardSync = DeviceCtlPasteboardSync

/// Provisioning or configuration profiles.
public typealias CoreDeviceProfileType = DeviceCtlProfileType
