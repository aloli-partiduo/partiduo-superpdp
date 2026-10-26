# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "http/server"

# Essai de bout en bout du raccordement par délégation OAuth (mode
# _authorization code_) contre le *vrai* bac à sable SUPER PDP (B-SPDP-004,
# D-SPDP-015). Il passe par le contrat de l'instance (`Superpdp::Api`),
# comme l'écran « Raccorder par SUPER PDP » :
#
# . lien d'autorisation généré par l'instance (`state` haché, PKCE) ;
# . ouverture du lien par l'utilisateur dans son navigateur (inscription,
#   consentement) ;
# . retour sur la route de rappel de l'instance, servie ici en local ;
# . échange du code, `GET /companies/me` (entreprise, bac à sable) ;
# . envoi d'une facture UBL PEPPOL BIS à l'entreprise belge de test (ligne
#   d'annuaire `0208`), puis réception chez elle.
#
# Lancé à la main seulement (nom sans `_spec` : jamais dans la suite) :
#
#   crystal spec --no-debug spec/integration/oauth_sandbox_essai.cr
#
# Identifiants (README, « Raccorder une entreprise par délégation OAuth ») :
# `SUPERPDP_SANDBOX_OAUTH_CLIENT_ID`, `SUPERPDP_SANDBOX_OAUTH_CLIENT_SECRET`
# (application OAuth bac à sable de l'opérateur),
# `SUPERPDP_SANDBOX_BUYER_CLIENT_ID`, `SUPERPDP_SANDBOX_BUYER_CLIENT_SECRET`
# (entreprise belge de test) ; facultatifs : `SUPERPDP_SANDBOX_OAUTH_PORT`
# (8765), `SUPERPDP_SANDBOX_OAUTH_LOGIN_HINT`. Lus par `SandboxEnv`. Sans
# eux, l'essai s'arrête avec un message d'aide. Aucune valeur secrète n'est
# affichée.
module Superpdp
  module SpecSupport
    module OAuthEssai
      REQUIRED = %w[SUPERPDP_SANDBOX_OAUTH_CLIENT_ID SUPERPDP_SANDBOX_OAUTH_CLIENT_SECRET
        SUPERPDP_SANDBOX_BUYER_CLIENT_ID SUPERPDP_SANDBOX_BUYER_CLIENT_SECRET]
      OPTIONAL     = %w[SUPERPDP_SANDBOX_OAUTH_PORT SUPERPDP_SANDBOX_OAUTH_LOGIN_HINT]
      DEFAULT_PORT = 8765

      # Temps laissé à l'utilisateur pour l'inscription dans son navigateur,
      # puis au traitement asynchrone de la plateforme.
      BROWSER_TIMEOUT  = 15.minutes
      PLATFORM_TIMEOUT = 120.seconds

      def self.values : Hash(String, String)
        SandboxEnv.load(REQUIRED + OPTIONAL)
      end

      def self.missing(values : Hash(String, String)) : Array(String)
        REQUIRED.reject { |name| values[name]?.presence }
      end

      def self.port(values : Hash(String, String)) : Int32
        values["SUPERPDP_SANDBOX_OAUTH_PORT"]?.try(&.to_i?) || DEFAULT_PORT
      end

      # Adresse de rappel à déclarer dans l'application OAuth bac à sable :
      # la route de rappel de l'instance (`superpdp:callback`), en local.
      def self.redirect_uri(port : Int32) : String
        "http://localhost:#{port}#{Superpdp::Ui.url("callback")}"
      end

      def self.help(missing : Array(String), port : Int32) : String
        String.build do |io|
          io << "\nEssai du raccordement SUPER PDP par délégation OAuth (bac à sable) : identifiants absents.\n\n"
          io << "Fichier lu : " << SandboxEnv.file << " (variable SUPERPDP_SANDBOX_ENV_FILE), lignes VAR=valeur ;\n"
          io << "l'environnement est prioritaire. Variables manquantes :\n"
          missing.each { |name| io << "  " << name << "\n" }
          io << "Facultatives : " << OPTIONAL.join(", ") << " (port local " << DEFAULT_PORT << " par défaut).\n\n"
          io << "Adresse de rappel à déclarer dans l'application OAuth bac à sable :\n  " << redirect_uri(port) << "\n\n"
          io << "Marche à suivre : README de partiduo-superpdp, « Raccorder une entreprise par délégation OAuth ».\n"
        end
      end

      # Route de rappel servie en local : rend les paramètres du premier
      # retour du parcours (`state`, `code` ou `error`).
      def self.wait_callback(port : Int32, path : String) : Hash(String, String)
        received = Channel(Hash(String, String)).new(1)
        server = HTTP::Server.new do |context|
          if context.request.path == path
            params = context.request.query_params.to_h
            context.response.content_type = "text/html; charset=utf-8"
            context.response.print "<!doctype html><meta charset=utf-8><title>Partiduo</title>" \
                                   "<p>Retour de SUPER PDP reçu : revenez au terminal.</p>"
            select
            when received.send(params)
            else
              # Retour déjà reçu : les suivants sont ignorés.
            end
          else
            context.response.status = HTTP::Status::NOT_FOUND
          end
        end
        server.bind_tcp("127.0.0.1", port)
        begin
          server.bind_tcp("::1", port)
        rescue Socket::Error
          # Pas d'IPv6 local : 127.0.0.1 suffit.
        end
        spawn { server.listen }
        select
        when params = received.receive
          params
        when timeout(BROWSER_TIMEOUT)
          raise "aucun retour de SUPER PDP sur #{path} après #{BROWSER_TIMEOUT.total_minutes.to_i} minutes"
        end
      ensure
        server.try(&.close)
      end

      def self.poll(what : String, &) : Nil
        deadline = Time.instant + PLATFORM_TIMEOUT
        loop do
          return if yield
          raise "délai dépassé en attendant : #{what}" if Time.instant > deadline
          sleep 3.seconds
        end
      end

      # Entreprise belge de test en mode _client credentials_.
      def self.buyer(values : Hash(String, String)) : Superpdp::Connector
        credentials = Superpdp::Credentials.new(values["SUPERPDP_SANDBOX_BUYER_CLIENT_ID"],
          values["SUPERPDP_SANDBOX_BUYER_CLIENT_SECRET"], Superpdp::CLIENT_CREDENTIALS)
        Superpdp::Connector.new(Superpdp::Client.new(credentials, Superpdp::MemoryStore.new))
      end

      # Numéro d'entreprise de la ligne d'annuaire belge (`0208:…`).
      def self.belgian_number(buyer : Superpdp::Connector) : String
        line = buyer.directory_entries.find { |item| item["identifier"]?.try(&.as_s?).to_s.starts_with?("0208:") }
        line || raise "l'entreprise belge de test n'a pas de ligne d'annuaire 0208 (README, étape « Entreprise belge de test »)"
        line["identifier"].as_s.lchop("0208:")
      end

      # Dernière facture reçue (curseur de départ).
      def self.last_incoming(connector : Superpdp::Connector) : Einvoicing::Connector::Cursor?
        params = URI::Params{"direction" => "in", "order" => "desc", "limit" => "1"}
        connector.client.get_json("/invoices", params)["data"].as_a.first?.try { |item| Einvoicing::Connector::Cursor.new(item["id"].as_i64.to_s) }
      end

      # Facture de test UBL PEPPOL BIS de l'entreprise raccordée : numéro
      # unique, acheteur adressé en `0208:<numéro>`.
      def self.invoice(seller : Superpdp::Connector, number : String, belgian : String) : Einvoicing::Connector::OutgoingInvoice
        xml, _ = seller.client.get_bytes("/invoices/generate_test_invoice", URI::Params{"format" => "ubl-peppol-bis"}, "application/xml")
        text = String.new(xml)
        text = text.sub(%r{<cbc:ID>[^<]*</cbc:ID>}, "<cbc:ID>#{number}</cbc:ID>")
        text = text.sub(%r{(<cac:AccountingCustomerParty>\s*<cac:Party>\s*<cbc:EndpointID)[^>]*>[^<]*(</cbc:EndpointID>)}m) do
          "#{$1} schemeID=\"0208\">#{belgian}#{$2}"
        end
        raise "facture de test sans destinataire 0208:#{belgian}" unless text.includes?(">#{belgian}</cbc:EndpointID>")
        content = text.to_slice
        Einvoicing::Connector::OutgoingInvoice.new(invoice_id: 0_i64, number: number, type_code: "380", syntax: "UBL",
          profile: "PEPPOL-BIS-3", filename: "#{number}.xml", content_type: "application/xml", content: content,
          processing_rule: "B2B", seller: Einvoicing::Connector::Party.new(name: "Entreprise raccordée", country_code: "FR"),
          buyer: Einvoicing::Connector::Party.new(name: "Entreprise belge de test", country_code: "BE"),
          tracking_id: "PDUO-#{UUID.random}", sha256: Digest::SHA256.hexdigest(content))
      end
    end
  end
end

describe "Raccordement SUPER PDP par délégation OAuth, bac à sable réel (essai manuel, B-SPDP-004)" do
  it "autorise l'entreprise, lit /companies/me, envoie une facture à l'entreprise belge de test qui la reçoit" do
    essai = Superpdp::SpecSupport::OAuthEssai
    values = essai.values
    port = essai.port(values)
    missing = essai.missing(values)
    unless missing.empty?
      STDERR.puts essai.help(missing, port)
      pending!("identifiants du bac à sable absents : #{missing.join(", ")}")
    end

    Einvoicing::Http.transport = Superpdp::SpecSupport::ProxyTransport.from_env
    Superpdp::Config.retry_delays = [1.seconds, 3.seconds]
    ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID"] = values["SUPERPDP_SANDBOX_OAUTH_CLIENT_ID"]
    ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET"] = values["SUPERPDP_SANDBOX_OAUTH_CLIENT_SECRET"]
    ENV.delete("PARTIDUO_SUPERPDP_REDIRECT_URI")
    Superpdp::SpecSupport.books("be")
    admin = Superpdp::SpecSupport.admin

    # 1. Lien d'autorisation généré par l'instance.
    redirect = essai.redirect_uri(port)
    input = Superpdp::Api::AuthorizationInput.new(redirect_uri: redirect, login_hint: values["SUPERPDP_SANDBOX_OAUTH_LOGIN_HINT"]? || "")
    start = Superpdp::Api.start_authorization(admin, input)
    start.errors.map { |error| "#{error.key} #{error.params}" }.should be_empty
    puts "\n\n1. Ouvrez ce lien dans votre navigateur, inscrivez l'entreprise bac à sable et donnez votre accord :\n\n   #{start.value!.url}\n"
    puts "   Retour attendu sur #{redirect} (#{Superpdp::SpecSupport::OAuthEssai::BROWSER_TIMEOUT.total_minutes.to_i} minutes au plus).\n"

    # 2. Retour sur la route de rappel, échange du code (PKCE).
    params = essai.wait_callback(port, Superpdp::Ui.url("callback"))
    callback = Superpdp::Api::CallbackInput.new(state: params["state"]? || "", code: params["code"]? || "",
      error: params["error"]? || "", error_description: params["error_description"]? || "")
    done = Superpdp::Api.complete_authorization(admin, callback)
    done.errors.map { |error| "#{error.key} #{error.params}" }.should be_empty
    status = done.value!
    {status.connected, status.auth_mode, status.mode}.should eq({true, Superpdp::AUTHORIZATION_CODE, "sandbox"})
    puts "2. Raccordée par délégation : #{status.company_name} (#{status.company_number_scheme} #{status.company_number}), vérification #{status.verification_status}."

    # 3. GET /companies/me avec le jeton délégué.
    seller = Superpdp::SpecSupport.connector
    company = seller.company
    company["env"].as_s.should eq("sandbox")
    puts "3. GET /companies/me : #{company["formal_name"]?}, environnement #{company["env"]}."

    # 4. Envoi à l'entreprise belge de test, puis réception chez elle.
    buyer = essai.buyer(values)
    belgian = essai.belgian_number(buyer)
    cursor = essai.last_incoming(buyer)
    number = "PDUO-OAUTH-#{Time.utc.to_s("%Y%m%d%H%M%S")}-#{Random::Secure.hex(2)}"
    submission = seller.submit(essai.invoice(seller, number, belgian))
    submission.status.should_not eq("error")
    puts "4. Facture #{number} déposée (#{submission.platform_ref}) pour 0208:#{belgian}."
    received = nil
    essai.poll("réception de la facture #{number} par l'entreprise belge de test") do
      loop do
        page = buyer.fetch_incoming(cursor)
        cursor = page.cursor
        received ||= page.items.find { |item| String.new(item.content).includes?(number) }
        break unless page.has_more
      end
      !received.nil?
    end
    received = received || raise "facture non reçue"
    Einvoicing::Formats::Reader.parse(received.content).number.should eq(number)
    puts "5. Reçue par l'entreprise belge de test (#{received.platform_ref}). Essai réussi : B-SPDP-004 peut être levé.\n"
  end
end
