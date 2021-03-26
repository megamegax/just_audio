
#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
    s.name             = 'just_audio_vlc'
    s.version          = '0.0.1'
    s.summary          = 'No-op implementation of just_audio_vlc plugin to avoid build issues on iOS'
    s.description      = <<-DESC
  temp fake just_audio_vlc plugin
                         DESC
    s.homepage         = 'https://github.com/ryanheise/just_audio/tree/master/just_audio_vlc'
    s.license          = { :file => '../LICENSE' }
    s.author           = { 'Your Company' => 'email@example.com' }
    s.source           = { :path => '.' }
    s.source_files = 'Classes/**/*'
    s.public_header_files = 'Classes/**/*.h'
    s.dependency 'Flutter'
  
    s.ios.deployment_target = '8.0'
  end