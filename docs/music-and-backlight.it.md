### Musica e retroilluminazione della tastiera (isola)

**Lettori.** La pagina Musica dell'isola controlla **Apple Music**, **Spotify** e **YouTube Music** riprodotto in
[Pear Desktop](https://github.com/th-ch/youtube-music) (l'app desktop che prima si chiamava "YouTube Music"). Quando più di uno
ha un brano, delle piccole etichette accanto al titolo passano dall'uno all'altro: quello che scegli resta mostrato finché ha un
brano; altrimenti si vede quello che suona, e un altro lettore messo in pausa non prende mai il suo posto.

**Comandi.** Casuale, precedente, **indietro di N secondi**, play/pausa, **avanti di N secondi**, successivo, la barra di
avanzamento, i testi (lrclib.net, solo se li attivi) e, dove il lettore lo consente:

| | Apple Music | Spotify | YouTube Music (Pear) |
|---|---|---|---|
| Salto indietro/avanti | sì (posizione esatta) | sì (posizione esatta) | sì (`go-back` / `go-forward`) |
| Preferito / Mi piace | sì (Preferiti) | **no**: lo scripting di Spotify non può salvare un brano | sì (Mi piace; premuto di nuovo lo toglie) |
| Volume del lettore | sì (`sound volume`) | sì (`sound volume`) | sì (`/volume`; muto vale 0) |
| Copertina | da Musica | dall'indirizzo https di Spotify | dall'indirizzo https del brano |

Il cursore del volume è il volume **del lettore**, non del Mac (quello del Mac resta sui tasti del volume e sull'HUD). Il passo
del salto è di 5, 10, 15 o 30 secondi (Impostazioni → Isola → *Musica e tastiera*, 15 di default).

**Apple Music e Spotify** annunciano da soli cosa suonano (nessun polling); Cocaine usa il loro scripting (il permesso
Automazione) per la copertina e, solo mentre la pagina Musica è a schermo, una volta al secondo per posizione, preferito e volume.

**YouTube Music tramite Pear Desktop.** Pear Desktop ha un plugin **API Server** (Plugins → API Server) che offre una piccola API
REST su questo Mac, porta **26538** di default. Per usarlo:

1. In Pear Desktop attiva *Plugins → API Server* (lascia la strategia di autorizzazione su quella di default, "Auth at first").
2. In Cocaine attiva Impostazioni → Isola → *Musica e tastiera* → **YouTube Music (Pear Desktop)** (oppure premi **Collega
   YouTube Music** nella pagina Musica vuota mentre Pear è aperto). Cambia lì la porta se l'hai cambiata in Pear.
3. Premi **Collega**: Pear mostra il suo dialogo che chiede di consentire il client "Cocaine". Consentilo. Pear risponde con un
   token che Cocaine tiene nel tuo **Portachiavi** (servizio `local.cocaine.media`); *Scollega* lo dimentica.

Nulla viene inviato a Pear prima che tu lo attivi. Cocaine parla solo con `127.0.0.1` (mai un altro host, mai tramite proxy,
nessun reindirizzamento seguito), con un timeout di 2 secondi per richiesta (la richiesta di autorizzazione aspetta fino a un
minuto la tua risposta in Pear). Mentre Pear è aperto e collegato chiede il brano corrente ogni 3 secondi (ogni secondo mentre
la pagina Musica è a schermo), e lo stato del Mi piace e il volume quando cambia brano. Se Pear rifiuta, o il suo plugin non
risponde, la pagina e le Impostazioni lo dicono (*rifiutato*, *non risponde: attiva il plugin API Server e controlla la porta*).

Il plugin di Pear di default ascolta su tutte le interfacce di rete (la sua impostazione `hostname`); è una scelta di Pear, non di
Cocaine. Se non vuoi che altri dispositivi della tua rete lo raggiungano, imposta il suo hostname a `127.0.0.1` nelle opzioni del
plugin in Pear.

**Non verificato dal vivo**: Pear Desktop non è installato sul Mac su cui è stato fatto. Il client segue il codice sorgente del
plugin (percorsi `/auth/{id}`, `/api/v1/song`, `/toggle-play`, `/next`, `/previous`, `/seek-to`, `/go-back`, `/go-forward`,
`/like`, `/like-state`, `/shuffle`, `/volume`) ed è provato contro un server finto (`--media-test`). L'id dell'app di Pear,
`com.github.th-ch.youtube-music`, è il modo in cui Cocaine vede che è aperto.

### Retroilluminazione della tastiera

Sui Mac con la tastiera retroilluminata (i MacBook), Cocaine può mostrarla e regolarla:

- **Nell'isola**: il modulo **Retroilluminazione tastiera** (aggiungilo a una schermata in Impostazioni → Isola → *Schermate*) e
  una riga in cima alla pagina Monitor, ognuno con un interruttore e un cursore. Quando Cocaine cambia il livello, l'HUD sotto il
  notch lo mostra.
- **Nelle Impostazioni** → Isola → *Musica e tastiera*: il livello, **Spegni quando inattivo** (mai, 30 s, 1, 2 o 5 min senza un
  tasto, un clic o un tocco; si riaccende al primo input) e **Solo mentre Cocaine tiene sveglio il Mac** (la regola vale solo
  allora). Se cambi tu il livello mentre è spenta per inattività, Cocaine lascia il tuo livello. Quando Cocaine si chiude
  riaccende ciò che aveva spento.

Anche macOS ha una sua impostazione (Impostazioni di Sistema → Tastiera → *Disattiva la retroilluminazione della tastiera dopo
un periodo di inattività*); puoi usare l'una o l'altra.

Come: macOS non ha un'API pubblica per la retroilluminazione della tastiera. Cocaine carica a runtime il framework privato di
Apple **CoreBrightness** e usa il suo `KeyboardBrightnessClient` (`brightnessForKeyboard:`, `setBrightness:forKeyboard:`),
verificando ogni metodo prima di chiamarlo. Se un aggiornamento di macOS lo cambia o lo toglie, o il Mac non ha la tastiera
retroilluminata, i controlli semplicemente non compaiono (le Impostazioni dicono *La tastiera di questo Mac non ha una
retroilluminazione che Cocaine possa controllare*). L'oscuramento automatico di macOS in base alla luce resta: quando macOS l'ha
spenta (luce forte, coperchio chiuso) l'isola lo dice.

Verificato su questo Mac **in sola lettura** (il livello è stato letto: `--media-test` lo stampa); nessun test ha scritto la
retroilluminazione vera: test e render usano un finto dispositivo.

### Test

`Cocaine --media-test` (in `verify.sh`): quale lettore si vede, i limiti del salto, l'AppleScript inviato a Musica e Spotify, le
richieste a Pear, il parsing, il consenso, il token e la regola "solo loopback" su un server finto, le regole di spegnimento
della retroilluminazione su un dispositivo finto e le operazioni in più dello scaffale su uno scaffale in memoria. Nessun
lettore, nessuna rete, nessuna retroilluminazione vera né dati dell'utente.
