# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/generators/anycable/setup/setup_generator"

describe AnyCableRailsGenerators::SetupGenerator, type: :generator do
  destination File.expand_path("../../../tmp/basic_rails_app", __dir__)

  let(:gen) { generator }
  let(:removed_files) { [] }

  before do
    prepare_destination

    FileUtils.cp_r File.expand_path("../../fixtures/basic_rails_app", __dir__),
      File.expand_path("../../../tmp", __dir__)

    FileUtils.rm(removed_files.map { |f| File.join(destination_root, f) }) if removed_files.any?
  end

  let(:default_opts) { %w[--skip-heroku --skip-install --skip-jwt --devenv skip] }

  context "when skip install environment" do
    subject { run_generator default_opts }

    it "copies config files" do
      subject
      expect(file("config/cable.yml")).to exist
      expect(file("config/anycable.yml")).to contain("broadcast_adapter: http")
    end

    context "when redis is in the deps" do
      before do
        File.write(
          File.join(destination_root, "Gemfile.lock"),
          <<~CODE
            GEM
              specs:
                redis
          CODE
        )
      end

      it "anycable.yml use redis broadcast adapter" do
        subject
        expect(file("config/anycable.yml")).not_to contain("broadcast_adapter: http")
        expect(file("config/anycable.yml")).to contain("broadcast_adapter: redis")
      end
    end

    it "patch environment configs" do
      subject
      expect(file("config/environments/development.rb"))
        .to contain('config.action_cable.url = ActionCable.server.config.url = ENV.fetch("CABLE_URL", "ws://localhost:8080/cable") if AnyCable::Rails.enabled?')

      expect(file("config/environments/production.rb"))
        .to contain('config.action_cable.url = ActionCable.server.config.url = ENV.fetch("CABLE_URL", "/cable") if AnyCable::Rails.enabled?')
    end
  end

  context "when docker environment" do
    it "shows a Docker Compose snippet" do
      gen = generator(default_opts + %w[--devenv=docker])
      expect(gen).to receive(:install_for_docker)
      silence_stream($stdout) { gen.invoke_all }
    end
  end

  context "when Heroku deployment" do
    subject { run_generator default_opts + %w[--skip-heroku=false] }

    before do
      File.write(
        File.join(destination_root, "Procfile"),
        <<~CODE
          web: bundle exec puma -C config/puma.rb
          worker: bundle exec lowkiq
          release: bundle exec rails db:migrate
        CODE
      )
    end

    it "updates Procfile", :aggregate_failures do
      subject
      expect(file("Procfile")).to contain(
        'web: [[ "$ANYCABLE_DEPLOYMENT" == "true" ]] && bundle exec anycable --server-command="anycable-go" || bundle exec puma -C config/puma.rb'
      )
      expect(file("Procfile")).to contain(
        "worker: bundle exec lowkiq"
      )
      expect(file("Procfile")).to contain(
        "release: bundle exec rails db:migrate"
      )
    end
  end

  context "when local environment" do
    context "when do not install the server" do
      subject do
        run_generator default_opts + %w[--devenv local --source skip --skip-procfile-dev false]
        file("Procfile.dev")
      end

      context "when Procfile.dev exists" do
        it "patches" do
          expect(subject)
            .to contain("anycable: bundle exec anycable")
          expect(subject)
            .to contain("ws: anycable-go --port=8080 --broadcast_adapter=http")
        end
      end

      context "when Procfile.dev is absent" do
        let(:removed_files) { %w[Procfile.dev] }

        it "creates" do
          expect(subject)
            .to contain("anycable: bundle exec anycable")
          expect(subject)
            .to contain("ws: anycable-go --port=8080 --broadcast_adapter=http")
        end

        context "when redis is in the deps" do
          before do
            File.write(
              File.join(destination_root, "Gemfile.lock"),
              <<~CODE
                GEM
                  specs:
                    redis
              CODE
            )
          end

          it "creates" do
            expect(subject)
              .to contain("anycable: bundle exec anycable")
            expect(subject)
              .to contain("ws: anycable-go --port=8080\n")
          end
        end
      end
    end

    context "when downloading binary" do
      it "runs curl with valid url" do
        gen = generator(default_opts + %w[--devenv local --source binary --os linux --cpu amd64 --skip-procfile-dev false])
        expect(gen)
          .to receive(:generate).with("anycable:download", "--os linux --cpu amd64 --bin-path=/usr/local/bin")
        silence_stream($stdout) { gen.invoke_all }
      end
    end

    context "when installing from Homebrew" do
      it "runs commands" do
        gen = generator(default_opts + %w[--devenv local --source brew --skip-procfile-dev false])
        expect(gen).to receive(:install_from_brew)
        silence_stream($stdout) { gen.invoke_all }
      end
    end
  end

  context "config/initializers/anycable.rb" do
    subject do
      run_generator default_opts
      file("config/initializers/anycable.rb")
    end

    context "when no devise.rb" do
      it "doesn't create anycable.rb initializer" do
        expect(subject).not_to exist
      end
    end

    context "when has devise.rb" do
      before do
        File.write(
          File.join(destination_root, "config/initializers/devise.rb"),
          <<~CODE
            # devise config
          CODE
        )
      end

      it "creates anycable.rb initializer" do
        expect(subject)
          .to contain("AnyCable::Rails::Rack.middleware.use Warden::Manager")
      end
    end
  end

  context "when RuboCop is present" do
    before do
      File.write(
        File.join(destination_root, "Gemfile.lock"),
        <<~CODE
          GEM
            specs:
              rubocop
        CODE
      )
    end

    it "runs compatibility checks" do
      gen = generator default_opts
      expect(gen)
        .to receive(:run).with(
          "bundle exec rubocop -r 'anycable/rails/compatibility/rubocop' " \
          "--only AnyCable/InstanceVars,AnyCable/PeriodicalTimers,AnyCable/InstanceVars"
        )
      silence_stream($stdout) { gen.invoke_all }
    end
  end

  context "with jwt" do
    it "adds anycable-rails-jwt gem" do
      gen = generator default_opts + %w[--skip-jwt false]
      expect(gen)
        .to receive(:run).with("bundle add anycable-rails-jwt --skip-install")

      silence_stream($stdout) { gen.invoke_all }
    end

    it "adds anycable-rails-jwt gem and install if not skipping install" do
      gen = generator default_opts + %w[--skip-jwt false --skip-install false]
      expect(gen)
        .to receive(:run).with("bundle add anycable-rails-jwt")

      silence_stream($stdout) { gen.invoke_all }
    end
  end
end
