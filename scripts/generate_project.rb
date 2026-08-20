#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "TimenBar.xcodeproj")

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2660"
project.root_object.attributes["LastUpgradeCheck"] = "2660"

main_group = project.main_group
app_group = main_group.new_group("TimenBar", "TimenBar")
tests_group = main_group.new_group("TimenBarTests", "TimenBarTests")
ui_tests_group = main_group.new_group("TimenBarUITests", "TimenBarUITests")

app_target = project.new_target(:application, "TimenBar", :osx, "14.0")
test_target = project.new_target(:unit_test_bundle, "TimenBarTests", :osx, "14.0")
ui_test_target = project.new_target(:ui_test_bundle, "TimenBarUITests", :osx, "14.0")
test_target.add_dependency(app_target)
ui_test_target.add_dependency(app_target)

def add_tree(group, disk_path, target, source_phase, resource_phase)
  Dir.children(disk_path).sort.each do |name|
    next if name.start_with?(".") || name.end_with?(".entitlements")

    full_path = File.join(disk_path, name)
    if File.directory?(full_path) && File.extname(name) != ".xcassets"
      child = group.new_group(name, name)
      add_tree(child, full_path, target, source_phase, resource_phase)
    else
      ref = group.new_file(name)
      case File.extname(name)
      when ".swift"
        source_phase.add_file_reference(ref)
      when ".xcassets", ".strings", ".json"
        resource_phase.add_file_reference(ref)
      end
    end
  end
end

add_tree(app_group, File.join(ROOT, "TimenBar"), app_target, app_target.source_build_phase, app_target.resources_build_phase)
if Dir.exist?(File.join(ROOT, "TimenBarTests"))
  add_tree(tests_group, File.join(ROOT, "TimenBarTests"), test_target, test_target.source_build_phase, test_target.resources_build_phase)
end
if Dir.exist?(File.join(ROOT, "TimenBarUITests"))
  add_tree(ui_tests_group, File.join(ROOT, "TimenBarUITests"), ui_test_target, ui_test_target.source_build_phase, ui_test_target.resources_build_phase)
end

def add_package(project, target, url, requirement, product_name)
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = url
  package.requirement = requirement
  project.root_object.package_references << package

  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = product_name
  target.package_product_dependencies << product

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

add_package(
  project,
  app_target,
  "https://github.com/modelcontextprotocol/swift-sdk.git",
  { "kind" => "exactVersion", "version" => "0.12.1" },
  "MCP"
)
add_package(
  project,
  app_target,
  "https://github.com/sparkle-project/Sparkle.git",
  { "kind" => "exactVersion", "version" => "2.9.2" },
  "Sparkle"
)

app_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "app.timenbar.TimenBar"
  settings["PRODUCT_NAME"] = "TimenBar"
  settings["SWIFT_VERSION"] = "6.0"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["INFOPLIST_KEY_LSUIElement"] = "YES"
  settings["INFOPLIST_KEY_LSApplicationCategoryType"] = "public.app-category.productivity"
  settings["INFOPLIST_KEY_NSHumanReadableCopyright"] = "Copyright © 2026 TimenBar contributors"
  settings["INFOPLIST_KEY_SUFeedURL"] = "https://timenbar.github.io/timenbar/appcast.xml"
  settings["INFOPLIST_KEY_SUPublicEDKey"] = ""
  settings["CODE_SIGN_ENTITLEMENTS"] = "TimenBar/TimenBar.entitlements"
  settings["ENABLE_APP_SANDBOX"] = "YES"
  settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["DEVELOPMENT_TEAM"] = "MMJZRMH2BA"
  settings["CURRENT_PROJECT_VERSION"] = "3"
  settings["MARKETING_VERSION"] = "0.1.1"
  settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  settings["DEAD_CODE_STRIPPING"] = "YES"
end

test_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "app.timenbar.TimenBarTests"
  settings["SWIFT_VERSION"] = "6.0"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/TimenBar.app/Contents/MacOS/TimenBar"
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
end

ui_test_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "app.timenbar.TimenBarUITests"
  settings["SWIFT_VERSION"] = "6.0"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
  settings["TEST_TARGET_NAME"] = "TimenBar"
end

project.save
puts "Generated #{PROJECT_PATH}"
