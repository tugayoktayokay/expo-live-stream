require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
require_relative 'ios/patch-haishinkit'

if defined?(Pod::Config)
  at_exit do
    begin
      patch_haishinkit_sources!(Pod::Config.instance.sandbox.root)
    rescue StandardError
      # Ignore sandbox errors outside pod install
    end
  end
end

Pod::Spec.new do |s|
  s.name           = 'ExpoLiveStream'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = 'expo-live-stream'
  s.homepage       = 'https://github.com/tugayoktayokay/expo-live-stream'
  s.platforms      = {
    :ios => '15.1'
  }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/tugayoktayokay/expo-live-stream' }
  s.static_framework = true

  s.dependency 'React-Core'
  if defined?(use_expo_modules!)
    s.dependency 'ExpoModulesCore'
  end
  s.dependency 'HaishinKit', '~> 2.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "ios/**/*.{h,m,mm,swift,hpp,cpp}"
end
