$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "identity_nation_builder/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "identity_nation_builder"
  s.version     = IdentityNationBuilder::VERSION
  s.authors     = ["GetUp!"]
  s.email       = ["tech@getup.org.au"]
  s.homepage    = "https://github.com/GetUp/identity_nation_builder"
  s.summary     = "Identity NationBuilder Integration."
  s.description = "Create and push members to NationBuilder Event RSVP."
  s.license     = "TBD"

  s.files = Dir["{app,config,db,lib}/**/*", "Rakefile", "README.md"]

  s.add_dependency "rails"
  s.add_dependency "pg"
  s.add_dependency "active_model_serializers"
  s.add_dependency "nationbuilder-rb"

end
