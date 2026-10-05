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
   firmata con **lo stesso certificato della copia in uso**;
3. mette al suo posto la nuova app con un'unica rinomina atomica, tenendo la precedente finché la nuova non è partita. Se
   qualcosa va storto la copia installata resta esattamente com'era; se la nuova versione non si apre, viene rimessa e
   aperta la precedente.

Non si aggiorna da sola, e lo dice, quando:

- l'hai installata con **Homebrew**: usa `brew upgrade --cask cocaine` (il pannello copia il comando), così i dati di
  Homebrew restano corretti;
- è firmata ad hoc, o è aperta dal .dmg o da una posizione in quarantena (spostala prima in Applicazioni);
- la sua cartella non è scrivibile da te (per esempio un account standard, non amministratore, e /Applicazioni): scaricala
  da GitHub.

Le copie precedenti all'aggiornamento dall'app (2.2.3 e prima) si aggiornano nel modo solito, una volta.

### Per chi pubblica le release

- `./build.sh --sign local|developer-id|adhoc` sceglie il livello e non ripiega mai su un altro. `--dmg --release` rifiuta
  ad hoc, non crea mai un nuovo certificato locale e richiede la chiave degli aggiornamenti; `--notarize` (solo Developer ID)
  notarizza e allega il ticket ad app e .dmg con `COCAINE_NOTARY_PROFILE`.
- `tools/update-key.sh init` crea una volta la coppia di chiavi (la privata resta in `~/.cocaine-signing/`, mai nel
  repository; fanne un backup: senza, nessuna copia installata può verificare una nuova release).
- `tools/release-sign.sh dist/Cocaine-<v>.dmg <livello>` scrive `Cocaine-<v>.dmg.manifest.json` dopo aver confrontato il
  livello dichiarato con l'app stessa. Carica entrambi i file nella release. Gli script non pubblicano nulla.
- `./verify.sh` compila ed esegue tutti i controlli automatici (anche su GitHub Actions); `tools/check-release.sh`
  controlla i file pubblicati.

Limiti: i passaggi Developer ID e notarizzazione sono scritti e provati con strumenti simulati, non ancora con il servizio
di Apple (serve un account sviluppatore a pagamento). Download, verifica e installazione degli aggiornamenti sono provati
con un server locale e chiavi usa e getta; il primo aggiornamento reale avverrà con la prima release che include un
manifest firmato.
