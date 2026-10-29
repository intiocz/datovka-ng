# ISDS API a co z něj Datovka NG používá

Přehled všech webových služeb ISDS podle WSDL ve `reference/isds-docs`
(WSDL 3.10–3.11, dokumentace WS 3.8 ze 7. 7. 2026, Provozní řád ze
26. 6. 2026) a stav v Datovce NG k 30. 10. 2026.

Značky:

| | |
|---|---|
| ✅ | implementováno a ověřeno na ostrém ISDS |
| 🧪 | implementováno, požadavek prošel kontrolou proti XSD, na ostrém ISDS zatím neověřeno |
| ◻️ | implementováno v jádře, aplikace to nepoužívá |
| ⬜ | chybí |
| — | nepotřebujeme (důvod v poznámce) |

Kontrola proti XSD: `core/src/isds/schema_check.rs`
(`DATOVKA_ISDS_XSD=reference/isds-docs cargo test -p datovka-core schema_check`),
všech 40 požadavků, které jádro umí sestavit. Výjimky: `UploadAttachment`
(příloha jako XOP odkaz, XSD ho nepopíše) a `CreateMessage`,
`CreateMultipleMessage`, `CreateBigMessage`. U těch obálka vynechává prázdné
prvky, které schéma vyžaduje jako `nil`. Ostré ISDS tvar bez nich přijímá,
ověřeno odesláním 29. 10. 2026. Plnou podobu podle schématu nasadíme až po
testu v testovacím prostředí.

Čtení na ostrém ISDS: `core/tests/production.rs`
(`DATOVKA_DIR=~/.dsgui DATOVKA_LIVE=1 cargo test -p datovka-core --test production -- --ignored`),
spuštěno 29. 10. 2026 na čtyřech schránkách s heslem, vše bez chyby.

## Služby a adresy

| Služba | Cesta | WSDL | Co dělá |
|---|---|---|---|
| dz | `DS/dz` | dm_operations | odeslání, stažení podepsané zprávy, ověření, přepodepsání |
| dx | `DS/dx` | dm_info | seznamy, obálky, doručenky, přečtení, smazání, autor, notifikace |
| df | `DS/df` | db_search | vyhledávání schránek, kredit, PDZ, trezor |
| DsManage | `DS/DsManage` | db_access, db_manipulations | údaje o účtu, heslo, uživatelé schránky, správa schránek |
| VoDZ | `DS/vodz` na **ws2** | dm_VoDZ (SOAP 1.2, MTOM/XOP) | velkoobjemové zprávy do 100 MB |
| arch | `DS/arch` na **ws2** | dm_arch (SOAP 1.2) | archivní razítko (přerazítkování) |
| asws | `asws/changePassword` na **www** | ChangePassword | změna hesla a SMS kód u přihlášení s kódem |
| Odesílací brána, autentizační služba | `asws/konceptEndpoint`, `atsEndpoint11`, `extWsEndpoint` na **cert** | SetConcept, GetCredential, ExtWs | pro serverové aplikace s registrací u DIA |

Adresy (od 25. 6. 2026 jen `*.datovka.gov.cz`, testovací prostředí
`*.datovka-test.gov.cz` od ledna 2026; `mojedatovaschranka.cz` a `czebox.cz`
se ruší, NG je už nepoužívá):

| Přihlášení | Produkce | Test | Stav |
|---|---|---|---|
| jméno + heslo (HTTP Basic, každé volání) | `https://ws1.datovka.gov.cz/DS/…`, VoDZ `ws2` | `ws1.datovka-test.gov.cz`, `ws2.…` | ✅ |
| jméno + heslo + SMS kód (TOTP) | `www.datovka.gov.cz/as/processLogin?type=totp…`, pak cookie a `www…/apps/DS/…` | `www.datovka-test.gov.cz` | 🧪 |
| jméno + heslo + kód z aplikace (HOTP) | totéž, `type=hotp` | | 🧪, **ISDS ho do budoucna ruší** |
| Mobilní klíč | `processLogin?type=mep-ws`, stav z `mepWsStateUpdate` | | ✅ (SVJ Helencina) |
| uživatelský certifikát + heslo | `https://ws1c.datovka.gov.cz/certds/DS/…`, VoDZ `ws2c` | `ws1c.datovka-test.gov.cz` | 🧪 |
| certifikát bez hesla | NG volá `ws1c…/hspis/DS/…` | | 🧪, **ověřit**: Provozní řád uvádí `hspis/` pro certifikát hostované spisové služby (jméno = ID schránky) a pro systémový certifikát `cert/DS/` |

Doručení přihlášením: podle Provozního řádu ho způsobuje **jen
`GetListOfReceivedMessages`**. Údaje o účtu (db_access), změna hesla
(asws), vyhledávání ani správa uživatelů doručení nezpůsobují.

## dz: zprávy (dm_operations)

| Operace | Stav | Jádro | V aplikaci |
|---|---|---|---|
| CreateMessage | ✅ (29. 10. 2026, odpověď FÚ s K rukám a č. j.) | `create_message` | Napsat zprávu, Odpovědět, Přeposlat, elektronická podání |
| CreateMultipleMessage | 🧪 | `create_multiple_message` | více adresátů (po 50) |
| SignedMessageDownload | ✅ denně | `download_received` | stahování přijatých |
| SignedSentMessageDownload | ✅ denně | `download_sent` | stahování odeslaných; nedodaná zpráva vrací 1229 a vezme se příště |
| MessageDownload | — | | nepodepsané XML; ukládáme podepsané ZFO |
| AuthenticateMessage | ✅ | `authenticate_message` | Ověřit zprávu v ISDS, Ověřit soubor ZFO |
| Re-signISDSDocument | 🧪 | `resign_document` | přerazítkování starých zpráv (když ArchiveISDSDocument vrátí 2214) |
| DummyOperation | — | | test spojení, nevyužito |

## VoDZ a archivní razítko (ws2, SOAP 1.2)

| Operace | Stav | Jádro | V aplikaci |
|---|---|---|---|
| UploadAttachment | 🧪 (bez XSD, XOP) | `upload_attachment` | odeslání nad 20 MB |
| CreateBigMessage | 🧪 | `create_big_message`, `send_big` | odeslání nad 20 MB |
| SignedBigMessageDownload | 🧪 | `download_big_received` | stahování, když běžné stažení selže |
| SignedSentBigMessageDownload | 🧪 | `download_big_sent` | totéž pro odeslané |
| AuthenticateBigMessage | 🧪 | `authenticate_big_message` | ověření VoDZ v ISDS |
| DownloadAttachment | ◻️ | `download_attachment` | přílohy bereme z podepsaného ZFO |
| BigMessageDownload | — | | nepodepsané XML |
| ArchiveISDSDocument | 🧪 | `archive_document` | Obnovit časové razítko, Nástroje → Časová razítka; okno jen posledních 1,5 roku platnosti (jinak 2206) |

## dx: informace o zprávách (dm_info)

| Operace | Stav | Jádro | V aplikaci |
|---|---|---|---|
| GetListOfReceivedMessages | ✅ denně | `received_messages` | stahování (**způsobuje doručení**) |
| GetListOfSentMessages | ✅ denně | `sent_messages` | stahování |
| GetSignedDeliveryInfo | ✅ denně | `download_delivery_info` | doručenka ke každé zprávě |
| GetDeliveryInfo | — | | nepodepsaná doručenka |
| MarkMessageAsDownloaded | 🧪 | `mark_as_read` | jen s volbou Nastavení → Označovat přečtení i v ISDS (výchozí vypnuto) |
| MessageEnvelopeDownload | — | | obálku máme ze seznamu a ze ZFO |
| SentMessageEnvelopeDownload | — | | totéž (nová od 5. 12. 2024) |
| GetMessageStateChanges | ✅ / ◻️ | `state_changes` | ověřeno, aplikace zatím nepoužívá; šlo by tím levně aktualizovat stav odeslaných (dodáno → doručeno) |
| GetMessageAuthor | — | | nahrazuje GetMessageAuthor2 |
| GetMessageAuthor2 | ✅ | `message_author` | menu zprávy → Autor |
| EraseMessage | 🧪 | `erase_message` | Smazat v ISDS (originál zůstane v archivu) |
| GetListOfErasedMessages | ✅ | `request_erased` | Informace o schránce → smazané zprávy (asynchronní) |
| PickUpAsyncResponse | ✅ | `pick_up_erased` | vyzvednutí seznamu smazaných (ZIP) |
| VerifyMessage | — | | zastaralé, nahrazuje AuthenticateMessage |
| RegisterForNotifications, GetListForNotifications | — | | pro serverové systémy; NG stahuje seznamy |
| SuspMessageReport | ⬜ | | nahlášení spamu (od 27. 3. 2025); kandidát do menu zprávy |
| ConfirmDelivery | — | | ve WSDL už není, PDZ se od 2022 doručují jako běžné zprávy |

## df: vyhledávání a informace o schránkách (db_search)

| Operace | Stav | Jádro | V aplikaci |
|---|---|---|---|
| ISDSSearch3 | ✅ | `search_boxes` | Adresář schránek, hledání adresáta při psaní (text, adresa, IČO, ID, IdOVM) |
| ISDSSearch2 | — | | starší verze |
| FindDataBox, FindDataBox2 | — | | pokrývá ISDSSearch3 |
| FindPersonalDataBox | — | | jen pro OVM |
| GetDataBoxList | — | | hromadné seznamy jsou jako otevřená data (SDS) |
| CheckDataBox | ✅ | `check_box` | kontrola adresáta po zadání |
| GetDataBoxActivityStatus | ⬜ | | historie zpřístupnění schránky; zatím nepotřeba |
| GetDataBoxAddress | ⬜ | | adresa po složkách (od 3. 10. 2024); zatím nepotřeba, hledání vrací složenou adresu |
| DataBoxCreditInfo | ✅ | `credit_info` | Informace o schránce → kredit |
| PDZInfo | ✅ | `pdz_info` | Informace o schránce → poštovní zprávy |
| PDZSendInfo | ✅ | `pdz_send_info` | nabídka typů PDZ při psaní |
| DTInfo | ✅ | `dt_info` | Informace o schránce → datový trezor |
| GetConstants | — | | konstanty VoDZ (limity), máme pevně |

## DsManage: účet a uživatelé (db_access, db_manipulations)

| Operace | Stav | Jádro | V aplikaci |
|---|---|---|---|
| GetOwnerInfoFromLogin | ✅ | `owner_info` | při přihlášení a přidání schránky |
| GetOwnerInfoFromLogin2 | ✅ | `owner_info2` | Informace o schránce |
| GetUserInfoFromLogin | — | | nahrazuje verze 2 |
| GetUserInfoFromLogin2 | ✅ | `user_info2` | Informace o schránce → uživatel |
| GetPasswordInfo | ✅ | `password_expiry` | upozornění na konec platnosti hesla |
| ChangeISDSPassword | 🧪 | `change_password` | změna hesla (schránky jen s heslem) |
| GetDataBoxUsers2 | ✅ | `box_users` | Uživatelé schránky |
| AddDataBoxUser2 | 🧪 | `add_user` | přidání pověřené osoby |
| UpdateDataBoxUser2 | 🧪 | `update_user` | změna oprávnění |
| DeleteDataBoxUser2 | 🧪 | `delete_user` | odebrání |
| AddDataBoxUser, UpdateDataBoxUser, DeleteDataBoxUser | — | | nahrazují verze 2 |
| CreateDataBox(2), DeleteDataBox(2), UpdateDataBoxDescr(2), NewAccessData(2), DisableDataBoxExternally(2), DisableOwnDataBox(2), EnableOwnDataBox(2), SetOpenAddressing, ClearOpenAddressing | — | | jen pro poskytovatele dat podle § 15 a 16 zákona (rejstříky, soudy) |

## asws: přihlášení s kódem (ChangePassword)

| Operace | Stav | Jádro | V aplikaci |
|---|---|---|---|
| SendSMSCode | 🧪 | `ops::send_sms_code` | Informace o schránce → změna hesla → Poslat SMS |
| ChangePasswordOTP | 🧪 | `ops::change_password_otp` | změna hesla u schránky se SMS nebo kódem z aplikace |

## Odesílací brána a autentizační služba

| Operace | Stav | Poznámka |
|---|---|---|
| SetConcept, SetMultipleConcept, SetBigConcept, GetPDZInfo | — | koncept zprávy, který uživatel schválí na portálu; pro webové aplikace s registrací |
| authConfirmation, heartBeat, RevokeConfirmation | — | přihlašování přes portál pro webové aplikace (autentizační služba PVS) |
| extWsLogout | — | odhlášení externí služby |

NG je desktopová a mobilní aplikace s vlastním přihlášením, tyhle služby
nepotřebuje.

## Změny ISDS, které nás čekají nebo už platí

| Od | Změna | Dopad na NG | Co udělat |
|---|---|---|---|
| 25. 6. 2026 (produkce), leden 2026 (test) | Domény `mojedatovaschranka.cz` → `datovka.gov.cz`, `czebox.cz` → `datovka-test.gov.cz`; staré adresy „výhledově ukončeny“ | NG už používá jen nové | nic; hlídat, že nikde nezůstala stará adresa (dnes žádná) |
| 25. 6. 2026 (WSDL 3.11) | Jemný typ schránky v `dmSenderType` (obálky, seznamy, doručenky, ZFO) místo hrubého | NG hodnotu jen ukládá do archivu jako číslo, nezobrazuje ji | až ji budeme zobrazovat, počítat s jemnými typy (číselník v dbTypes.xsd) |
| 16. 4. 2026 (WSDL 3.10) | Virtuální typy `OVM_MAIN`, `PFO_BASE`, `PO_BASE` ve FindDataBox2 a ISDSSearch3 | NG filtruje jen „OVM“ / „vše“ | volitelně nabídnout filtr podle těchto typů |
| 1. 1. 2026 | Přílohy DDD (digitální tachografy) povoleny | NG typ přílohy neomezuje, kontroluje ISDS | nic |
| 4. 12. 2025 | Okno pro ArchiveISDSDocument jinak na produkci a v testu (test od druhého dne) | v testovacím prostředí půjde přerazítkování zkoušet hned | využít při testech |
| 18. 9. 2025 (WSDL 3.09) | ArchiveISDSDocument (archivní razítko), CAdES pečeť podle novější ETSI normy, AV kontrola až ~240 s (chyba 2046 u UploadAttachment) | ArchiveISDSDocument používáme; ověřování podpisu zvládá nové pečetě (ověřeno na tvých zprávách) | ošetřit chybu 2046 česky a delší timeout u VoDZ (dnes 120 s) |
| 27. 3. 2025 (WSDL 3.08) | SuspMessageReport, příznak „podezřelá zpráva“ (`specMessFlag="1"`) u přijatých | NG příznak nečte ani nezobrazuje | zobrazit varování u zprávy a přidat „Nahlásit jako spam“ |
| 5. 12. 2024 | Nejvýš 100 příloh, z toho 10 kontejnerů (ZIP/ASiC); pečeť RSA-PSS | ověřování RSA-PSS funguje | upozornit už při psaní, ne až chybou z ISDS |
| trvá | HOTP „nebude do budoucna podporován“ (Provozní řád) | přihlášení kódem z aplikace (HOTP) časem přestane fungovat | při přidání schránky doporučit Mobilní klíč; hlídat oznámení DIA |
| trvá | Limity provozu: sleduje se stahování zpráv, doručenek, seznamů a označování přečtení; nad limit zpomalení 3 s, souběžný požadavek odmítnut | NG stahuje jen nové zprávy a schránky postupně | nespouštět stahování jedné schránky souběžně (dnes ho blokuje `sync.running`, ale rychlé stažení odeslané zprávy volá `sync` mimo něj) |
| trvá | Aplikace na lokální stanici se mají přihlašovat „na manuální příkaz uživatele“, serverové mohou automaticky | NG (stejně jako původní Datovka) stahuje automaticky každých 15 minut | zvážit delší výchozí interval nebo upozornění v Nastavení |

## Co chybí ověřit (testovací prostředí)

Na ostrém ISDS se nezkouší nic, co něco mění, stojí peníze nebo posílá
zprávy cizím adresátům. Potřebujeme testovací schránky (zřizují se v ostré
schránce: Nastavení → Pro vývojáře → Zřídit schránku v testovacím prostředí),
ideálně dvě, aby si posílaly zprávy.

| Co | Operace |
|---|---|
| obálka v plné podobě podle XSD (prázdné prvky jako `nil`) | CreateMessage, CreateMultipleMessage, CreateBigMessage |
| více adresátů, poštovní zprávy (iniciační, odpověď) | CreateMultipleMessage, CreateMessage s `dmType` |
| velkoobjemová zpráva tam i zpět, ověření | UploadAttachment, CreateBigMessage, Signed(Sent)BigMessageDownload, AuthenticateBigMessage |
| smazání zprávy | EraseMessage |
| přečtení v ISDS | MarkMessageAsDownloaded |
| přerazítkování (v testu jde hned) | ArchiveISDSDocument, Re-signISDSDocument |
| změna hesla | ChangeISDSPassword, SendSMSCode, ChangePasswordOTP |
| správa uživatelů | AddDataBoxUser2, UpdateDataBoxUser2, DeleteDataBoxUser2 |
| přihlášení | SMS (TOTP), kód z aplikace (HOTP), certifikát (`certds/`, a `hspis/` vs `cert/`) |
