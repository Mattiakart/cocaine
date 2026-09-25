<p align="center"><img src="docs/icona.png" width="128" alt="Icona di Cocaine"></p>

<h1 align="center">Cocaine</h1>

<p align="center"><b>Tiene sveglio il Mac, anche col coperchio chiuso.</b><br>
Una piccola app gratuita e open source per la barra dei menu di macOS.</p>

<p align="center"><img src="docs/demo.gif" width="360" alt="La bustina nella barra dei menu si riempie quando Cocaine si attiva"></p>

🇬🇧 [Read in English](README.md)

- **Bustina piena = attivo.** Il Mac non va in stop, nemmeno col coperchio chiuso. Funziona anche su Apple Silicon,
  senza componenti aggiuntivi da installare.
- **Bustina vuota = spento.** Il Mac si comporta normalmente.
- **Parla la tua lingua:** italiano, inglese, cinese (semplificato e tradizionale), spagnolo, francese, tedesco e giapponese.
  Segue la lingua del Mac (altrimenti l'inglese), oppure la scegli dalla bandiera nel pannello.
- **Luminosità.** Mentre è attivo, può abbassare lo schermo integrato al livello che scegli dopo qualche minuto di
  inattività. Lo schermo non si spegne mai del tutto, e torna com'era appena tocchi tastiera o trackpad.

<p align="center"><img src="docs/pannello.png" width="340" alt="Il pannello di Cocaine"></p>

Richiede macOS 14 (Sonoma) o successivo. Funziona su Mac Apple Silicon e Intel, pesa circa 600 KB, è gratis.

## Installazione

**Con Homebrew (il modo più semplice):**

```
brew install --cask mattiakart/tap/cocaine
```

Homebrew ti chiede la password del Mac **una volta**, direttamente nel Terminale, per dare il permesso a Cocaine. Se hai attivato
Touch ID per sudo, basta l'impronta. Nient'altro: nessuna finestra, niente "Apri comunque".
`brew upgrade` non chiede mai nulla, e `brew uninstall --cask cocaine` toglie tutto senza chiedere.

**Oppure scarica il .dmg** dalla pagina [Releases](../../releases/latest):

1. Apri il `.dmg` e trascina **Cocaine** in **Applicazioni**.
2. Aprila. macOS la blocca, perché l'app non è firmata da uno sviluppatore registrato presso Apple:
   vai in **Impostazioni di Sistema → Privacy e sicurezza** e clicca **"Apri comunque"**. Serve solo la prima volta.
3. Cocaine chiede **una volta** la password. macOS la mostra con un avviso perché l'app non è verificata da Apple: è normale.

In entrambi i casi quell'autorizzazione installa una regola sudo che permette solo `pmset -a disablesleep 1`,
`pmset -a disablesleep 0` e la cancellazione della regola stessa. Nient'altro.

## Da sapere

- Mentre Cocaine è attivo il Mac **non si blocca da solo**, anche col coperchio chiuso: bloccalo con ⌃⌘Q.
- A batteria e col coperchio chiuso il Mac continua a consumare, e non va in stop nemmeno con la batteria quasi scarica.
- Quando apri l'app, Cocaine si attiva, e quando la chiudi si disattiva. Vale per **Esci**, ⌘Q, la disconnessione e lo spegnimento.

## Disinstallazione

Con Homebrew: `brew uninstall --cask cocaine`. Spegne Cocaine e toglie l'app e la regola sudo, senza chiedere nulla.
(`--zap` cancella anche le impostazioni.)

Senza Homebrew: esci da Cocaine (così si spegne), spostala nel Cestino, poi nel Terminale:

```
sudo rm /etc/sudoers.d/cocaine
```

## Come funziona

- `pmset -a disablesleep 1` impedisce lo stop, anche a coperchio chiuso. L'app installa una regola sudo che
  permette senza password **solo** i due comandi `pmset -a disablesleep 1` e `pmset -a disablesleep 0`.
- Mentre è attivo, `caffeinate -d` tiene acceso lo schermo.
- La luminosità è gestita con le API DisplayServices di macOS.

Codice: `main.swift` (app per la barra dei menu, Swift/SwiftUI) e `cocaine.zsh` (lo script "motore").
Per compilare: `./build.sh --dmg`.

## Licenza

MIT: vedi [LICENSE](LICENSE).
