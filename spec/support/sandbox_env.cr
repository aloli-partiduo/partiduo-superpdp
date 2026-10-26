# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  module SpecSupport
    # Identifiants du bac à sable SUPER PDP pour les essais réels (suite
    # d'intégration, essai du raccordement par délégation OAuth) : lus dans
    # le fichier `SUPERPDP_SANDBOX_ENV_FILE`, à défaut
    # `~/.config/partiduo/superpdp-sandbox.env` (lignes `VAR=valeur`, lues
    # comme le shell : `export`, commentaire final, guillemets), puis dans
    # l'environnement, prioritaire. Les valeurs ne sont jamais affichées.
    module SandboxEnv
      DEFAULT_FILE = Path.home.join(".config", "partiduo", "superpdp-sandbox.env").to_s

      def self.file : String
        ENV["SUPERPDP_SANDBOX_ENV_FILE"]?.presence || DEFAULT_FILE
      end

      # Valeurs non vides des variables demandées.
      def self.load(names : Array(String)) : Hash(String, String)
        values = {} of String => String
        path = file
        if File.file?(path)
          File.each_line(path) do |line|
            name, separator, value = line.strip.partition('=')
            next if separator.empty? || name.starts_with?('#')
            name = name.lchop("export ").strip
            next unless names.includes?(name)
            value = value.sub(/\s+#.*\z/, "").strip
            value = value[1..-2] if value.size >= 2 && value[0] == value[-1] && value[0].in?('"', '\'')
            values[name] = value unless value.empty?
          end
        end
        names.each { |name| ENV[name]?.presence.try { |value| values[name] = value } }
        values
      end
    end
  end
end
