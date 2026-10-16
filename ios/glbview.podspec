#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint glbview.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'glbview'
  s.version          = '0.0.1'
  s.summary          = 'Native GLB viewer rendered with Metal.'
  s.description      = <<-DESC
Displays binary glTF 2.0 models rendered natively with Metal into a Flutter texture.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'glbview/Sources/glbview/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.frameworks = 'Metal', 'MetalKit', 'CoreVideo', 'QuartzCore'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'glbview_privacy' => ['glbview/Sources/glbview/PrivacyInfo.xcprivacy']}
end
