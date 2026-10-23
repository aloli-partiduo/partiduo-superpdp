# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/SUPERPDP/` servie en `GET` (liste tirée du routeur de Marten),
# obtenue dans chaque langue de l'interface (`Partiduo::LOCALES`) par un
# administrateur, SUPER PDP d'abord non raccordé (application d'opérateur
# présente : les deux modes de raccordement), puis raccordé (lignes
# d'annuaire, régime de TVA). Contrôle de l'interface
# (`PartiduoUi::Translations`) : ni marqueur de traduction absente, ni clé
# brute, ni interpolation non résolue, et toute route atteinte par les
# liens des pages.

private alias S = Superpdp::SpecSupport

describe "Traductions des écrans SUPER PDP (chaque langue de l'interface)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    S.books
    browser = PartiduoUi::Accounts.signed_in
    S.company
    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("superpdp:"))
    S.with_operator do
      # Graine : route de rappel, appelée par SUPER PDP au retour du
      # parcours d'autorisation (aucun lien) ; son GET renvoie à l'écran.
      explorer.crawl(browser, "SUPERPDP non raccordé", ["/ext/SUPERPDP/oauth/callback?error=access_denied"])
      # Message laissé par le retour refusé.
      explorer.visit(browser, "SUPERPDP non raccordé", ["/ext/SUPERPDP/"])
    end
    S.connect
    explorer.crawl(browser, "SUPERPDP raccordé")
    puts "\nTraductions de SUPERPDP : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  ensure
    # L'exploration laisse active la dernière langue demandée : les
    # exemples suivants attendent la langue par défaut.
    I18n.activate(Marten.settings.i18n.default_locale)
  end
end
