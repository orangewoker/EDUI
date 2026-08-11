#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'

project_path = File.expand_path('Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' }
abort 'Runner target not found' unless runner

pubspec_path = File.expand_path('../pubspec.yaml', __dir__)
full_version = File.read(pubspec_path)[/^version:\s*([^\s]+)/, 1]
abort 'Version not found in pubspec.yaml' unless full_version
app_version, build_number = full_version.split('+', 2)
abort 'Build number not found in pubspec.yaml version' unless build_number

widget = project.targets.find { |target| target.name == 'EDUIWidget' }
group = project.main_group.find_subpath('EDUIWidget', true)
group.set_source_tree('<group>')
group.path = 'EDUIWidget'
unless widget
  widget = project.new_target(:app_extension, 'EDUIWidget', :ios, '17.0')
  widget.product_reference.name = 'EDUIWidget.appex'

  swift_ref = group.files.find { |file| file.path == 'EDUIWidget.swift' } || group.new_file('EDUIWidget.swift')
  group.files.find { |file| file.path == 'Info.plist' } || group.new_file('Info.plist')
  widget.source_build_phase.add_file_reference(swift_ref)

  runner.add_dependency(widget)
  embed_phase = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed Foundation Extensions' }
  embed_phase ||= runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embed_phase.dst_subfolder_spec = '13'
  embed_phase.add_file_reference(widget.product_reference, true)
end

runner.build_configurations.each do |config|
  config.build_settings.delete('CODE_SIGN_ENTITLEMENTS')
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
end

# Flutter's "Thin Binary" phase reads the finished Runner.app. Embedding the
# extension after that phase creates an Xcode dependency cycle, so keep the
# extension copy phase immediately before Thin Binary.
embed_phase = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed Foundation Extensions' }
if embed_phase
  phases = runner.build_phases
  phases.delete(embed_phase)
  thin_index = phases.index { |phase| phase.respond_to?(:name) && phase.name == 'Thin Binary' }
  phases.insert(thin_index || phases.length, embed_phase)
end

widget.build_configurations.each do |config|
  settings = config.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings.delete('CODE_SIGN_ENTITLEMENTS')
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  # Widget targets do not inherit Flutter/Generated.xcconfig. Use literal
  # values so ProcessInfoPlistFile always writes both required version keys.
  settings['CURRENT_PROJECT_VERSION'] = build_number
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'EDUIWidget/Info.plist'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  settings['MARKETING_VERSION'] = app_version
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.orangewoker.edui.widget'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end

group.files
  .select { |file| file.path&.end_with?('.entitlements') }
  .each(&:remove_from_project)

project.save
puts 'EDUIWidget target is configured.'
