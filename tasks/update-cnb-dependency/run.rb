#!/usr/bin/env ruby
require 'json'
require 'toml'
require 'tmpdir'
require_relative './dependencies'

ALL_STACKS = {
    'cflinuxfs2' => 'org.cloudfoundry.stacks.cflinuxfs2',
    'cflinuxfs3' => 'org.cloudfoundry.stacks.cflinuxfs3',
    'bionic' => 'io.buildpacks.stacks.bionic'
}

V3_DEP_IDS = {
    'php' => 'php-binary'
}

V3_DEP_NAMES = {
    'node' => 'Node Engine',
    'yarn' => 'Yarn',
    'python' => 'Python',
    'php' => 'PHP',
    'httpd' => 'Apache HTTP Server'
}

buildpacks_ci_dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))
require_relative "#{buildpacks_ci_dir}/lib/git-client"

buildpack_toml = TOML.load_file('buildpack/buildpack.toml')
buildpack_toml_latest_released = begin
  TOML.load_file('buildpack-latest-released/buildpack.toml')
rescue
  {'metadata' => {'dependencies' => []}}
end

data = JSON.parse(open('source/data.json').read)
manifest_name = data.dig('source', 'name')
resource_version = data.dig('version', 'ref')
story_id = JSON.parse(open("builds/binary-builds-new/#{manifest_name}/#{resource_version}.json").read)['tracker_story_id']
removal_strategy  = ENV['REMOVAL_STRATEGY']
version_line_type = ENV['VERSION_LINE_TYPE']
version_line      = ENV['VERSION_LINE']
deprecation_date  = ENV['DEPRECATION_DATE']
deprecation_link  = ENV['DEPRECATION_LINK']
deprecation_match = ENV['DEPRECATION_MATCH']

system('rsync -a buildpack/ artifacts/')
raise 'Could not copy buildpack to artifacts' unless $?.success?

added = []
removed = []
rebuilt = []
total_stacks = []
builds = {}

Dir["builds/binary-builds-new/#{manifest_name}/#{resource_version}-*.json"].each do |stack_dependency_build|
  unless deprecation_date.nil? or deprecation_link.nil? or version_line == 'latest'
    dependency_deprecation_date = {'version_line' => version_line.downcase, 'name' => manifest_name, 'date' => deprecation_date, 'link' => deprecation_link, }
    dependency_deprecation_date['match'] = deprecation_match unless deprecation_match.nil? or deprecation_match.empty? or deprecation_match.downcase == 'null'

    deprecation_dates = buildpack_toml['metadata'].fetch('dependency_deprecation_dates', [])
    deprecation_dates = deprecation_dates.reject{ |d| d['version_line'] == version_line.downcase and d['name'] == manifest_name}.push(dependency_deprecation_date).sort_by{ |d| [d['name'], d['version_line'] ]}
    buildpack_toml['metadata']['dependency_deprecation_dates'] = deprecation_dates
  end

  stack = /#{resource_version}-(.*)\.json$/.match(stack_dependency_build)[1]

  if stack == 'any-stack'
    total_stacks.concat ALL_STACKS.values
    v3_stacks = ALL_STACKS.values
  else
    next unless ALL_STACKS.keys.include? stack
    total_stacks.push ALL_STACKS[stack]
    v3_stacks = [ALL_STACKS[stack]]
  end

  build = JSON.parse(open(stack_dependency_build).read)
  builds[stack] = build

  version = builds[stack]['version'] # We assume that the version is the same for all stacks
  source_type = 'source'
  source_url = ''
  source_sha256 = ''

  begin
    source_url = builds[stack]['source']['url']
    source_sha256 = builds[stack]['source'].fetch('sha256', '')
  rescue
    next
  end

  if manifest_name.include? 'dotnet'
    git_commit_sha = builds[stack]['git_commit_sha']
    source_url = "#{source_url}/archive/#{git_commit_sha}.tar.gz"
  elsif manifest_name == 'appdynamics'
    source_type = 'osl'
    source_url = 'https://docs.appdynamics.com/display/DASH/Legal+Notices'
  elsif manifest_name == 'CAAPM'
    source_type = 'osl'
    source_url = 'https://docops.ca.com/ca-apm/10-5/en/ca-apm-release-notes/third-party-software-acknowledgments/php-agents-third-party-software-acknowledgments'
  elsif manifest_name.include? 'miniconda'
    source_url = "https://github.com/conda/conda/archive/#{version}.tar.gz"
  end

  dep = {
      'id' => V3_DEP_IDS.fetch(manifest_name, manifest_name),
      'name' => V3_DEP_NAMES[manifest_name],
      'version' => resource_version,
      'uri' => build['url'],
      'sha256' => build['sha256'],
      'stacks' => v3_stacks,
      source_type => source_url,
      'source_sha256' => source_sha256
  }

  old_deps = buildpack_toml['metadata'].fetch('dependencies', [])
  old_versions = old_deps
                     .select {|d| d['id'] == V3_DEP_IDS.fetch(manifest_name, manifest_name)}
                     .map {|d| d['version']}

  buildpack_toml['metadata']['dependencies'] = Dependencies.new(
      dep,
      version_line_type,
      removal_strategy,
      old_deps,
      buildpack_toml_latest_released['metadata'].fetch('dependencies', [])
  ).switch

  new_versions = buildpack_toml['metadata']['dependencies']
                     .select {|d| d['id'] == V3_DEP_IDS.fetch(manifest_name, manifest_name)}
                     .map {|d| d['version']}

  added += (new_versions - old_versions).uniq.sort
  removed += (old_versions - new_versions).uniq.sort
  rebuilt += [old_versions.include?(resource_version)]
end

rebuilt = rebuilt.all?()
puts 'REBUILD: skipping most version updating logic' if rebuilt

if added.empty? && !rebuilt
  puts 'SKIP: Built version is not required by buildpack.'
  exit 0
end

commit_message = "Add #{manifest_name} #{resource_version}"
commit_message = "Rebuild #{manifest_name} #{resource_version}" if rebuilt
if removed.length > 0
  commit_message = "#{commit_message}, remove #{manifest_name} #{removed.join(', ')}"
end
commit_message = commit_message + "\n\nfor stack(s) #{total_stacks.join(', ')}"

Dir.chdir('artifacts') do
  GitClient.set_global_config('user.email', 'cf-buildpacks-eng@pivotal.io')
  GitClient.set_global_config('user.name', 'CF Buildpacks Team CI Server')

  File.write('buildpack.toml', TOML::Generator.new(buildpack_toml).body)
  GitClient.add_file('buildpack.toml')

  GitClient.safe_commit("#{commit_message} [##{story_id}]")
end
