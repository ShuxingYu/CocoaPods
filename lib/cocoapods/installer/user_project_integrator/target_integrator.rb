require 'active_support'

module Pod
  class Installer
    class UserProjectIntegrator

      # This class is responsible for integrating the library generated by a
      # {TargetDefinition} with its destination project.
      #
      class TargetIntegrator

        # @return [Target] the target that should be integrated.
        #
        attr_reader :target

        # @param  [Target] target @see #target_definition
        #
        def initialize(target)
          @target = target
        end

        # Integrates the user project targets. Only the targets that do **not**
        # already have the Pods library in their frameworks build phase are
        # processed.
        #
        # @return [void]
        #
        def integrate!
          UI.section(integration_message) do
            add_xcconfig_base_configuration
            add_pods_library
            add_copy_resources_script_phase
            add_check_manifest_lock_script_phase
            save_projects
          end
        end

        # @return [Array<PBXNativeTarget>] the user targets for integration.
        #
        def native_targets
          @native_targets ||= target.user_target_uuids.map { |uuid| user_project.objects_by_uuid[uuid] }
        end

        # Read the project from the disk to ensure that it is up to date as
        # other TargetIntegrators might have modified it.
        #
        def user_project
          @user_project ||= Xcodeproj::Project.new(target.user_project_path)
        end

        # Read the pods project from the disk to ensure that it is up to date as
        # other TargetIntegrators might have modified it.
        #
        def pods_project
          @pods_project ||= Xcodeproj::Project.new(target.sandbox.project_path)
        end

        # @return [String] a string representation suitable for debugging.
        #
        def inspect
          "#<#{self.class} for target `#{target_definition.label}'>"
        end

        #---------------------------------------------------------------------#

        # @!group Integration steps

        private

        # @return [Specification::Consumer] the consumer for the specifications.
        #
        def spec_consumers
          @spec_consumers ||= target.libraries.map(&:file_accessors).flatten.map(&:spec_consumer)
        end

        # Adds the `xcconfig` configurations files generated for the current
        # {TargetDefinition} to the build configurations of the targets that
        # should be integrated.
        #
        # @note   It also checks if any build setting of the build
        #         configurations overrides the `xcconfig` file and warns the
        #         user.
        #
        # @todo   If the xcconfig is already set don't override it and inform
        #         the user.
        #
        # @return [void]
        #
        def add_xcconfig_base_configuration
          xcconfig = user_project.files.select { |f| f.path == target.xcconfig_relative_path }.first ||
                     user_project.new_file(target.xcconfig_relative_path)
          native_targets.each do |native_target|
            check_overridden_build_settings(target.xcconfig, native_target)
            native_target.build_configurations.each do |config|
              config.base_configuration_reference = xcconfig
            end
          end
        end

        # Adds spec libraries to the frameworks build phase of the
        # {TargetDefinition} integration libraries. Adds a file reference to
        # the library of the {TargetDefinition} and adds it to the frameworks
        # build phase of the targets.
        #
        # @return [void]
        #
        def add_pods_library
          native_target = pods_project.targets.select { |t| t.name == target.name }.first
          products = pods_project.products_group
          target.libraries.each do |library|
            product = products.files.select { |f| f.path == library.product_name }.first
            native_target.frameworks_build_phase.add_file_reference(product)
          end

          frameworks = user_project.frameworks_group
          native_targets.each do |native_target|
            library = frameworks.files.select { |f| f.path == target.product_name }.first ||
                      frameworks.new_static_library(target.name)
            unless native_target.frameworks_build_phase.files_references.include?(library)
                   native_target.frameworks_build_phase.add_file_reference(library)
            end
          end
        end

        # Adds a shell script build phase responsible to copy the resources
        # generated by the TargetDefinition to the bundle of the product of the
        # targets.
        #
        # @return [void]
        #
        def add_copy_resources_script_phase
          phase_name = "Copy Pods Resources"
          native_targets.each do |native_target|
            phase = native_target.shell_script_build_phases.select { |bp| bp.name == phase_name }.first ||
                    native_target.new_shell_script_build_phase(phase_name)
            path  = target.copy_resources_script_relative_path
            phase.shell_script = %{"#{path}"\n}
          end
        end

        # Adds a shell script build phase responsible for checking if the Pods
        # locked in the Pods/Manifest.lock file are in sync with the Pods defined
        # in the Podfile.lock.
        #
        # @note   The build phase is appended to the front because to fail
        #         fast.
        #
        # @return [void]
        #
        def add_check_manifest_lock_script_phase
          phase_name = 'Check Pods Manifest.lock'
          native_targets.each do |native_target|
            next if native_target.shell_script_build_phases.any? { |phase| phase.name == phase_name }
            phase = native_target.project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
            native_target.build_phases.unshift(phase)
            phase.name = phase_name
            phase.shell_script = <<-EOS.strip_heredoc
              diff "${PODS_ROOT}/../Podfile.lock" "${PODS_ROOT}/Manifest.lock" > /dev/null
              if [[ $? != 0 ]] ; then
                  cat << EOM
              error: The sandbox is not in sync with the Podfile.lock. Run 'pod install' or update your CocoaPods installation.
              EOM
                  exit 1
              fi
            EOS
          end
        end

        # Saves the changes to the user project to the disk.
        #
        # @return [void]
        #
        def save_projects
          user_project.save_as(target.user_project_path)
          pods_project.save_as(target.sandbox.project_path)
        end

        #---------------------------------------------------------------------#

        # @!group Private helpers.

        private

        # Informs the user about any build setting of the target which might
        # override the given xcconfig file.
        #
        # @return [void]
        #
        def check_overridden_build_settings(xcconfig, native_target)
          return unless xcconfig

          configs_by_overridden_key = {}
          native_target.build_configurations.each do |config|
            xcconfig.attributes.keys.each do |key|
              target_value = config.build_settings[key]

              if target_value && !target_value.include?('$(inherited)')
                configs_by_overridden_key[key] ||= []
                configs_by_overridden_key[key] << config.name
              end
            end

            configs_by_overridden_key.each do |key, config_names|
              name    = "#{native_target.name} [#{config_names.join(' - ')}]"
              actions = [
                "Use the `$(inherited)` flag, or",
                "Remove the build settings from the target."
              ]
              UI.warn("The target `#{name}` overrides the `#{key}` build " \
                      "setting defined in `#{target.xcconfig_relative_path}'.",
                      actions)
            end
          end
        end

        # @return [String] the message that should be displayed for the target
        #         integration.
        #
        def integration_message
          "Integrating #{'library'.pluralize(target.libraries.size)} " \
            "`#{target.libraries.map(&:name).to_sentence}` " \
            "into target #{target.name} " \
            "of project #{UI.path target.user_project_path}."
        end

        #---------------------------------------------------------------------#

      end
    end
  end
end
