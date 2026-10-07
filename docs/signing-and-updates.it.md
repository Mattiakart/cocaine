## Firma, primo avvio e aggiornamenti

### Come è firmato Cocaine

Ci sono tre livelli di firma. Il pannello dice quale ha la tua copia, sotto **Permessi**.

| Livello | Cos'è | Primo avvio dal .dmg | Permessi tra un aggiornamento e l'altro |
|---|---|---|---|
| **Locale** (release attuali) | Firmato con un certificato autofirmato di Cocaine. Gratis, ma Apple non lo verifica. | macOS lo blocca una volta: **Impostazioni di Sistema → Privacy e sicurezza → Apri comunque**. | Restano negli aggiornamenti firmati con lo stesso certificato (vedi sotto). |
| **Developer ID** | Firmato con un certificato Apple Developer ID, hardened runtime. | Bloccato comunque, se non è anche notarizzato. | Restano negli aggiornamenti firmati con lo stesso Developer ID. |
| **Developer ID, notarizzato** | Come sopra, più il controllo di Apple, con il ticket allegato all'app e al .dmg. | Si apre normalmente, senza "Apri comunque". | Restano negli aggiornamenti firmati con lo stesso Developer ID. |

Le build **ad hoc** (senza certificato) esistono solo se qualcuno compila Cocaine con `--sign adhoc` di proposito. macOS
considera ogni build ad hoc un'app nuova, quindi dimentica i permessi a ogni aggiornamento, e una copia così non può
aggiornarsi da sola.

Con Homebrew non serve "Apri comunque": il cask toglie il flag di quarantena del download durante l'installazione.

### Cosa resta dopo un aggiornamento e cosa no

- **Impostazioni, regola sudo e hook degli avvisi AI** non dipendono dalla firma: restano sempre.
- **I permessi** (Accessibilità, Fotocamera, Calendario, Musica e Spotify, File) macOS li lega al *requisito designato*
  dell'app, che per Cocaine è "questo bundle ID, firmato con questo certificato". Un aggiornamento firmato con lo stesso
  certificato soddisfa lo stesso requisito, quindi macOS può mantenerli. `tools/verify-permissions-persistence.sh` fa lo
  stesso controllo del requisito su due build (passa tra la 2.2.3 e la build attuale). Apple però non garantisce
  nulla per i certificati autofirmati: se dopo un aggiornamento un interruttore si spegne, riaccendilo una volta.
- **Non restano** quando cambia il certificato: per esempio la prima release firmata con Developer ID invece del certificato
  locale, una copia compilata da te (con il tuo certificato) o qualsiasi build ad hoc. macOS richiede i permessi, una volta.

### Aggiornamenti dall'app

In **Cocaine → Aggiornamenti** il pannello mostra se c'è una nuova versione. Con **Cerca aggiornamenti automaticamente**
attivo (predefinito) chiede a GitHub al massimo una volta al giorno; non scarica nulla finché non premi **Installa** e non
mostra mai finestre.

Quando premi **Installa**, Cocaine:

1. scarica il .dmg solo dalle release GitHub di questo repository, in una cartella privata. Se il download si interrompe
   (rete, stop, uscita dall'app) riprende da dove si era fermato; si ferma alla dimensione promessa, controlla prima lo
   spazio libero e ritenta qualche volta in caso di errori di rete;
2. lo verifica prima di toccare qualsiasi cosa: il manifest della release deve avere una firma Ed25519 valida, fatta con
   la chiave incorporata in Cocaine; il .dmg deve corrispondere a SHA-256 e dimensione firmati; versione e build devono
   essere più recenti delle tue (niente downgrade, niente riuso di una release vecchia); e l'app al suo interno deve essere
   firmata con **lo stesso certificato della copia in uso** (i manifest nuovi indicano quel certificato, così una copia
   firmata con un altro lo sa prima di scaricare). Il .dmg viene ricontrollato subito prima di essere aperto;
3. mette al suo posto la nuova app con un'unica rinomina atomica e la avvia. La versione precedente resta finché la nuova
   non ha funzionato per 20 secondi (o è stata chiusa prima): se la nuova non si apre, va in crash o si blocca, viene
   chiusa, la precedente viene rimessa e aperta e il pannello dice che l'aggiornamento è stato annullato. Se qualcosa va
   storto prima dello scambio, la copia installata resta esattamente com'era.

Non si aggiorna da sola, e lo dice, quando:

- l'hai installata con **Homebrew**: usa `brew upgrade --cask cocaine` (il pannello copia il comando), così i dati di
  Homebrew restano corretti;
- è firmata ad hoc, o è aperta dal .dmg, da una posizione in quarantena o da una cartella di build (spostala prima in
  Applicazioni);
- la sua cartella, o l'app stessa, non è scrivibile da te (per esempio un account standard, non amministratore, e
  /Applicazioni): scaricala da GitHub;
- la release è firmata con un certificato diverso da quello della tua copia (scaricala da GitHub);
- la release è difettosa: per esempio una versione più recente con un numero di build non più alto (viene segnalato,
  mai mostrato come "aggiornato").

**Le copie della 2.3.0 e della 2.4.0 non possono aggiornarsi da sole**: quelle release sono state compilate senza la
chiave degli aggiornamenti e pubblicate senza manifest firmato, quindi il pannello dice solo che esiste una nuova
versione. Aggiornale con Homebrew o da GitHub, una volta. Anche le copie precedenti all'aggiornamento dall'app (2.2.3 e
prima) si aggiornano nel modo solito, una volta.

### Per chi pubblica le release

- `./build.sh --sign local|developer-id|adhoc` sceglie il livello e non ripiega mai su un altro. La build va in
  `build.noindex/` (`build` è un collegamento). `--dmg` è sempre una build di release: rifiuta ad hoc, non crea mai un
  nuovo certificato locale e richiede la chiave degli aggiornamenti incorporata; `--allow-unsigned-updates` crea comunque
  un DMG così e avvisa che le sue copie non potranno aggiornarsi da sole. `--notarize` (solo Developer ID) notarizza e
  allega il ticket ad app e .dmg con `COCAINE_NOTARY_PROFILE`.
- **Prima della prossima release (un passo da fare una volta, a mano, da chi pubblica):** `tools/update-key.sh init` crea
  la coppia di chiavi (la privata va in `~/.cocaine-signing/update-ed25519.key`, mai nel repository; fanne un backup
  offline: senza, nessuna copia installata può verificare una nuova release, e sostituirla blocca gli aggiornamenti di
  tutte le copie) e incorpora la pubblica in `Sources/UpdateKey.swift`; fai il commit di quel file.
- `tools/release-sign.sh dist/Cocaine-<v>.dmg <livello>` scrive `Cocaine-<v>.dmg.manifest.json` (formato 2: firma anche il
  requisito designato dell'app) dopo aver confrontato il livello dichiarato con l'app stessa, e rifiuta un numero di build
  non più alto di quello dell'ultima release (`tools/last-release`, che poi aggiorna: fanne il commit). Carica entrambi i
  file nella release. Gli script non pubblicano nulla.
- `./build.sh` (installazione) mette la build in /Applicazioni se lì c'è già una copia (dice quando è quella di Homebrew),
  altrimenti in ~/Applicazioni, e rimuove l'altra copia: un solo Cocaine sul Mac. Chiude solo il Cocaine aperto da quelle
  copie (dal loro percorso), lo aspetta, e non tocca l'app installata se qualcosa non si può fare.
- `./verify.sh` compila ed esegue tutti i controlli automatici (anche su GitHub Actions, con una versione di Xcode
  fissata); le suite dell'app girano da una copia con un bundle id suo e controlla che nessuna impostazione sia stata
  scritta. `tools/check-release.sh` controlla i file pubblicati (`COCAINE_NO_MANIFEST=1` per 2.3.0/2.4.0, senza manifest).

Limiti: i passaggi Developer ID e notarizzazione sono scritti e provati con strumenti simulati, non ancora con il servizio
di Apple (serve un account sviluppatore a pagamento). Download, verifica, installazione e ripristino degli aggiornamenti
sono provati con un server locale, chiavi usa e getta e app sostitutive; il primo aggiornamento reale avverrà con la prima
release che include un manifest firmato.
