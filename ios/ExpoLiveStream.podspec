require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoLiveStream'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author'] || 'expo-live-stream'
  s.homepage       = 'https://github.com/tugayoktayokay/expo-live-stream'
  s.platforms      = {
    :ios => '15.1'
  }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/tugayoktayokay/expo-live-stream' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.dependency 'HaishinKit', '~> 2.0'
  
  # VLCKit projeye devasa boyut katar ve C++ bağımlılıkları çeker. 
  # Sadece izleyici (player) için kullanıyorsan kalsın.
  s.dependency 'MobileVLCKit', '~> 3.6.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Expo modüllerinde derleme hızını ve optimizasyonunu artırır:
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    # Eğer başka kütüphaneler (VLC vb.) flag eziyorsa, Expo'nun standart flaglerini korur:
    'OTHER_LDFLAGS' => '$(inherited)' 
  }

  # C++ veya Objective-C++ kullanmıyorsan cpp, hpp ve mm uzantılarını buradan silmek 
  # duplicate -lc++ uyarısını tamamen ortadan kaldırır. 
  # (Şimdilik standart Expo şablonu olarak bıraktım, uyarı zararsızdır).
  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
end