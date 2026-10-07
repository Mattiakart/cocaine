# L'isola su ogni schermo, il suo HUD e il feedback aptico

## Un'isola per ogni schermo collegato

- Ogni schermo collegato ha un'isola: il notch dove c'è, una pillola sottile (150 pt, alta quanto la barra dei menu di quello
  schermo) sugli altri. Un gruppo di schermi duplicati ne ha una sola. L'isola principale (il notch integrato, altrimenti un
  notch qualsiasi, altrimenti lo schermo integrato, altrimenti quello principale) viene prima. Isola → *Mostra su tutti gli
  schermi* (attivo di serie) spento tiene solo l'isola principale, come nella 2.5.0.
- Ogni isola ha la sua geometria e la sua finestra; le pagine e i dati sono condivisi. Si apre un'isola alla volta: il
  puntatore sul notch dello schermo B apre l'isola di B e chiude quella di A. Un'isola con una domanda resta aperta finché non
  rispondi; una aperta con ⌃⌥⌘I (sullo schermo del puntatore) resta quando il puntatore va altrove.
- Un'app a schermo intero nasconde solo l'isola del suo schermo. Schermi collegati, scollegati, spostati, scalati, duplicati o
  coperchio chiuso: ogni isola viene riposizionata subito (e ricontrollata ogni 1,2 s); un'isola aperta su uno schermo che sparisce
  si chiude.
- Il pannello delle impostazioni e i suoi dialoghi pendono dal notch dello schermo su cui stai lavorando: l'isola aperta per
  ultima, o lo schermo del puntatore quando chiedi il pannello. Solo quell'isola si fa da parte.
- Un solo timer controlla tutte le isole. L'icona nella barra dei menu torna solo se nessuna isola può essere mostrata.

## L'HUD sotto il notch

- Barre di volume e luminosità e i brevi avvisi (Scaricato, Copiato, AirDrop, scorciatoie, caricatore, fine focus, AI)
  compaiono in un contenitore appeso subito sotto il notch: largo quanto il notch (la pillola sugli schermi senza notch),
  centrato, unito al suo bordo inferiore con piccoli raccordi e gli angoli arrotondati dell'isola, nero.
- Un tasto tenuto premuto o pressioni rapide aggiornano lo stesso contenitore: la barra scorre al nuovo valore e il tempo si
  allunga; volume poi luminosità scambia icona ed etichetta al suo interno. Rientra nel notch dopo 1,4 s di quiete. Un avviso più
  recente sostituisce quello mostrato; una barra che arriva sopra un avviso lo mette da parte e l'avviso torna dopo le barre.
- Si ritira quando la sua isola si apre. Con Riduci movimento sfuma invece di muoversi.
- Su quale schermo: luminosità → lo schermo che il tasto ha cambiato; tutto il resto → lo schermo sotto il puntatore, altrimenti
  l'isola principale. Gli altri schermi restano tranquilli. Se lo schermo dell'HUD sparisce, l'HUD passa allo schermo del puntatore.

## Feedback aptico: uno per azione

- Un clic su un trackpad Force Touch è già un tocco aptico. La 2.5.0 ne aggiungeva un altro in ogni pulsante: il doppio tocco.
  Ora durante un clic Cocaine non aggiunge nulla; i tocchi senza clic (trascinare su un magnete, il righello del focus, lo
  scorrimento a due dita, l'isola che si apre al passaggio del puntatore, la tastiera) restano. Lo stesso tocco due volte entro
  60 ms suona una volta sola.
