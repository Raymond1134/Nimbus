# Uncomment the next line to define a global platform for your project
platform :ios, '14.0'

target 'Nimbus' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  # Pods for Nimbus
  pod 'DJI-SDK-iOS', '~> 4.12'
  pod 'DJIWidget', '~> 1.6'

end

# Inject Secrets.xcconfig into the CocoaPods xcconfig chain so that
# build variables like DJI_APP_KEY resolve in Info.plist.
# This runs automatically after every `pod install`.
post_install do |installer|
  Dir.glob('Pods/Target Support Files/Pods-Nimbus/Pods-Nimbus.*.xcconfig') do |path|
    content = File.read(path)
    include_line = "#include? \"../../../Nimbus/Secrets.xcconfig\""
    unless content.include?(include_line)
      File.open(path, 'a') { |f| f.puts "\n#{include_line}" }
    end
  end
end
