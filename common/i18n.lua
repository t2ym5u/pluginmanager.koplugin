-- i18n.lua — Plugin translation module
--
-- Drop-in replacement for `local _ = require("gettext")` in plugin screens.
-- Priority: custom table → KOReader gettext → original string.
--
-- To add a language, extend each entry:
--   ["English key"] = { fr = "Traduction", de = "Übersetzung", es = "Traducción" }
--
-- Usage:
--   local _ = require("i18n")   -- works exactly like _() from gettext
--   local i18n = require("i18n")
--   i18n.lang()                  -- returns "fr", "en", etc.

local koreader_t = require("gettext")

local function lang()
    return (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
end

-- ---------------------------------------------------------------------------
-- Translation table
-- Key   = English source string (as written in _("...") calls)
-- Value = table mapping language code → translated string
-- ---------------------------------------------------------------------------
local S = {

    -- -----------------------------------------------------------------------
    -- Common buttons
    -- -----------------------------------------------------------------------
    ["New game"]    = { fr = "Nouvelle partie" },
    ["New"]         = { fr = "Nouveau" },
    ["Close"]       = { fr = "Fermer" },
    ["Rules"]       = { fr = "Règles" },
    ["Check"]       = { fr = "Vérifier" },
    ["Undo"]        = { fr = "Annuler" },
    ["Erase"]       = { fr = "Effacer" },
    ["Clear"]       = { fr = "Effacer tout" },
    ["Clear All"]   = { fr = "Tout effacer" },
    ["Hint"]        = { fr = "Indice" },
    ["Reveal"]      = { fr = "Révéler" },
    ["Reset"]       = { fr = "Réinitialiser" },
    ["Restart"]     = { fr = "Recommencer" },
    ["Solve"]       = { fr = "Résoudre" },
    ["Submit"]      = { fr = "Valider" },
    ["Guess"]       = { fr = "Deviner" },
    ["Validate"]    = { fr = "Valider" },
    ["Stop"]        = { fr = "Arrêter" },
    ["Roll"]        = { fr = "Lancer" },
    ["Roll dice"]   = { fr = "Lancer les dés" },
    ["Show"]        = { fr = "Afficher" },
    ["Hide"]        = { fr = "Masquer" },
    ["Fill"]        = { fr = "Remplir" },
    ["Done"]        = { fr = "Terminé" },
    ["Weigh"]       = { fr = "Peser" },
    ["Settings"]    = { fr = "Réglages" },
    ["About"]       = { fr = "À propos" },
    ["Solution"]    = { fr = "Solution" },
    ["Solutions"]   = { fr = "Solutions" },
    ["Show result"] = { fr = "Voir la solution" },
    ["Hide result"] = { fr = "Masquer la solution" },
    ["Clear Pans"]  = { fr = "Vider les plateaux" },

    -- -----------------------------------------------------------------------
    -- Note / Flag / Fill modes
    -- -----------------------------------------------------------------------
    ["Note: On"]    = { fr = "Notes : actif" },
    ["Note: Off"]   = { fr = "Notes : inactif" },
    ["Note: ON"]    = { fr = "Notes : ON" },
    ["Note: OFF"]   = { fr = "Notes : OFF" },
    ["Flag: ON"]    = { fr = "Drapeau : ON" },
    ["Flag: OFF"]   = { fr = "Drapeau : OFF" },
    ["Fill mode"]   = { fr = "Mode remplissage" },
    ["Cross mode"]  = { fr = "Mode croix" },
    ["Cross"]       = { fr = "Croix" },

    -- -----------------------------------------------------------------------
    -- Difficulty levels
    -- -----------------------------------------------------------------------
    ["Easy"]    = { fr = "Facile" },
    ["Medium"]  = { fr = "Moyen" },
    ["Hard"]    = { fr = "Difficile" },
    ["Expert"]  = { fr = "Expert" },

    -- -----------------------------------------------------------------------
    -- Directions (crossword / kakuro)
    -- -----------------------------------------------------------------------
    ["Across"]               = { fr = "Horizontal" },
    ["Down"]                 = { fr = "Vertical" },
    ["Across: %1 (have %2)"] = { fr = "Horizontal : %1 (obtenu %2)" },
    ["Down: %1 (have %2)"]   = { fr = "Vertical : %1 (obtenu %2)" },

    -- -----------------------------------------------------------------------
    -- Weighings (balance)
    -- -----------------------------------------------------------------------
    ["Heavier"]                            = { fr = "Plus lourd" },
    ["Lighter"]                            = { fr = "Plus léger" },
    ["heavier"]                            = { fr = "plus lourd" },
    ["lighter"]                            = { fr = "plus léger" },
    ["Heavier or lighter?"]                = { fr = "Plus lourd ou plus léger ?" },
    ["Which ball is the odd one?"]         = { fr = "Quelle bille est la différente ?" },
    ["No weighings yet"]                   = { fr = "Aucune pesée pour l'instant" },
    ["No weighings remaining — make your guess!"] = { fr = "Plus de pesées — faites votre choix !" },
    ["Weighings: %1/%2"]                   = { fr = "Pesées : %1/%2" },
    ["Correct! Ball %1 was %2."]           = { fr = "Correct ! La bille %1 était %2." },
    ["Wrong! Ball %1 was %2."]             = { fr = "Faux ! La bille %1 était %2." },
    ["Correct! Weighings: %1/%2"]          = { fr = "Correct ! Pesées : %1/%2" },
    ["Correct! Wins: %1"]                  = { fr = "Correct ! Victoires : %1" },
    ["Game over. Odd ball was #%1 (%2)."]  = { fr = "Partie terminée. La bille différente était la n°%1 (%2)." },
    ["Place balls on the pans first."]     = { fr = "Placez d'abord les billes sur les plateaux." },

    -- -----------------------------------------------------------------------
    -- Menus
    -- -----------------------------------------------------------------------
    ["Select difficulty"]   = { fr = "Choisir la difficulté" },
    ["Select grid size"]    = { fr = "Choisir la taille de la grille" },
    ["Select disk count"]   = { fr = "Choisir le nombre de disques" },
    ["Select preset"]       = { fr = "Choisir un niveau" },
    ["Language"]            = { fr = "Langue" },
    ["English"]             = { fr = "Anglais" },
    ["Difficulty"]          = { fr = "Difficulté" },
    ["Grid size"]           = { fr = "Taille de la grille" },
    ["Number of symbols"]   = { fr = "Nombre de symboles" },
    ["Code length"]         = { fr = "Longueur du code" },
    ["Max attempts"]        = { fr = "Nombre maximal de tentatives" },
    ["Allow duplicates"]    = { fr = "Doublons autorisés" },
    ["Auto-save"]           = { fr = "Sauvegarde automatique" },
    ["Gameplay"]            = { fr = "Jeu" },
    ["Game options"]        = { fr = "Options du jeu" },
    ["Game"]                = { fr = "Jeu" },
    ["Duration"]            = { fr = "Durée" },
    ["Time"]                = { fr = "Temps" },
    ["Size: %1"]            = { fr = "Taille : %1" },
    ["Grid: %1"]            = { fr = "Grille : %1" },
    ["Diff: %1"]            = { fr = "Difficulté : %1" },
    ["Diff: %1 (%2)"]       = { fr = "Difficulté : %1 (%2)" },
    ["Difficulty: %1"]      = { fr = "Difficulté : %1" },
    ["Level %1/%2"]         = { fr = "Niveau %1/%2" },
    ["On"]                  = { fr = "Actif" },
    ["Off"]                 = { fr = "Inactif" },
    ["Select"]              = { fr = "Sélectionner" },
    ["Select size"]         = { fr = "Choisir la taille" },

    -- -----------------------------------------------------------------------
    -- Common status — victories
    -- -----------------------------------------------------------------------
    ["Congratulations! Puzzle solved."]       = { fr = "Félicitations ! Puzzle résolu." },
    ["Congratulations! Puzzle solved!"]       = { fr = "Félicitations ! Puzzle résolu !" },
    ["Congratulations! All galaxies complete!"] = { fr = "Félicitations ! Toutes les galaxies sont complètes !" },
    ["Congratulations! All paths connected!"] = { fr = "Félicitations ! Tous les chemins sont connectés !" },
    ["Congratulations! All words found!"]     = { fr = "Félicitations ! Tous les mots sont trouvés !" },
    ["Congratulations! Loop complete!"]       = { fr = "Félicitations ! Boucle complète !" },
    ["Congratulations! You cleared the board!"] = { fr = "Félicitations ! Vous avez résolu le plateau !" },
    ["Congratulations! %1 moves (optimal: %2)"] = { fr = "Félicitations ! %1 déplacements (optimal : %2)" },
    ["Puzzle solved!"]                        = { fr = "Puzzle résolu !" },
    ["Puzzle complete!"]                      = { fr = "Puzzle terminé !" },
    ["Puzzle %1 solved!"]                     = { fr = "Puzzle %1 résolu !" },
    ["Solved!"]                               = { fr = "Résolu !" },
    ["Solved! All islands connected!"]        = { fr = "Résolu ! Toutes les îles sont connectées !" },
    ["Solved! Moves: %1  Pushes: %2"]         = { fr = "Résolu ! Déplacements : %1  Poussées : %2" },
    ["Solved! Wins: %1"]                      = { fr = "Résolu ! Victoires : %1" },
    ["Solved in %1 moves! Best: %2"]          = { fr = "Résolu en %1 coups ! Meilleur : %2" },
    ["Solved in %1! Streak: %2"]              = { fr = "Résolu en %1 ! Série : %2" },
    ["All cells illuminated! Puzzle solved!"] = { fr = "Toutes les cases illuminées ! Puzzle résolu !" },
    ["Fleet found! Puzzle solved!"]           = { fr = "Flotte trouvée ! Puzzle résolu !" },
    ["All words found!"]                      = { fr = "Tous les mots trouvés !" },

    -- -----------------------------------------------------------------------
    -- Common status — errors / validation
    -- -----------------------------------------------------------------------
    ["Keep going!"]                          = { fr = "Continuez !" },
    ["No errors found!"]                     = { fr = "Aucune erreur trouvée !" },
    ["No errors found so far."]              = { fr = "Aucune erreur pour l'instant." },
    ["No clue violations so far."]           = { fr = "Aucune violation d'indice pour l'instant." },
    ["No violations found so far."]          = { fr = "Aucune violation pour l'instant." },
    ["Everything looks good!"]               = { fr = "Tout est correct !" },
    ["There are mistakes highlighted."]      = { fr = "Les erreurs sont mises en évidence." },
    ["Some cells are incorrect."]            = { fr = "Certaines cases sont incorrectes." },
    ["Some cells have errors."]              = { fr = "Certaines cases contiennent des erreurs." },
    ["Wrong cells marked."]                  = { fr = "Cases incorrectes marquées." },
    ["Check: %1 violation(s) found."]        = { fr = "Vérification : %1 violation(s) trouvée(s)." },
    ["Check: %1 incorrect cell(s)."]         = { fr = "Vérification : %1 case(s) incorrecte(s)." },
    ["Check: %1 clue(s) exceeded."]          = { fr = "Vérification : %1 indice(s) dépassé(s)." },
    ["Check done. %1 cell(s) remaining."]    = { fr = "Vérification effectuée. %1 case(s) restante(s)." },
    ["Check done. Empty cells: %1"]          = { fr = "Vérification effectuée. Cases vides : %1" },
    ["Check done. Empty: %1"]               = { fr = "Vérification effectuée. Vides : %1" },
    ["Checking…"]                            = { fr = "Vérification…" },

    -- -----------------------------------------------------------------------
    -- Common status — undo / moves
    -- -----------------------------------------------------------------------
    ["Last move undone."]       = { fr = "Dernier coup annulé." },
    ["Nothing to undo."]        = { fr = "Rien à annuler." },
    ["Invalid move."]           = { fr = "Coup invalide." },
    ["Board cleared."]          = { fr = "Plateau effacé." },
    ["New game started."]       = { fr = "Nouvelle partie lancée." },
    ["New %1 game started."]    = { fr = "Nouvelle partie %1 lancée." },
    ["Started a %1 game."]      = { fr = "Partie %1 lancée." },

    -- -----------------------------------------------------------------------
    -- Common status — game over
    -- -----------------------------------------------------------------------
    ["Game over."]                         = { fr = "Partie terminée." },
    ["Game over. Start a new game."]       = { fr = "Partie terminée. Lancez une nouvelle partie." },
    ["Game over. Secret was: %1"]          = { fr = "Partie terminée. Le secret était : %1" },
    ["Game over! The secret code was: %1"] = { fr = "Partie terminée ! Le code secret était : %1" },
    ["Game over! Final score: %1 worms"]   = { fr = "Partie terminée ! Score final : %1 vers" },
    ["Game over! Score: %1  Words: %2/%3"] = { fr = "Partie terminée ! Score : %1  Mots : %2/%3" },
    ["BOOM! Game over."]                   = { fr = "BOOM ! Partie terminée." },
    ["No moves left. Game over!"]          = { fr = "Plus de coups possibles. Partie terminée !" },

    -- -----------------------------------------------------------------------
    -- Common status — cells / selection
    -- -----------------------------------------------------------------------
    ["Empty cells: %1"]                          = { fr = "Cases vides : %1" },
    ["Cannot edit a given cell."]                = { fr = "Impossible de modifier une case donnée." },
    ["Tap a cell first."]                        = { fr = "Appuyez d'abord sur une case." },
    ["Tap a cipher letter first."]               = { fr = "Appuyez d'abord sur une lettre chiffrée." },
    ["Cell %1,%2 selected."]                     = { fr = "Case %1,%2 sélectionnée." },
    ["Selected: %1,%2  ·  Empty cells: %3"]      = { fr = "Sélection : %1,%2  ·  Cases vides : %3" },
    ["Selected: %1,%2  ·  Empty: %3%4"]          = { fr = "Sélection : %1,%2  ·  Vides : %3%4" },
    ["Selected: %1,%2  \xC2\xB7  Empty cells: %3"] = { fr = "Sélection : %1,%2  ·  Cases vides : %3" },

    -- -----------------------------------------------------------------------
    -- Common status — solution display
    -- -----------------------------------------------------------------------
    ["Solution shown."]                          = { fr = "Solution affichée." },
    ["Solution revealed."]                       = { fr = "Solution révélée." },
    ["Showing the solution."]                    = { fr = "Affichage de la solution." },
    ["Showing solution. Editing disabled."]      = { fr = "Solution affichée. Modification désactivée." },
    ["Solution is shown; editing is disabled."]  = { fr = "Solution affichée ; modification désactivée." },
    ["Result is being shown; editing is disabled."] = { fr = "Résultat affiché ; modification désactivée." },

    -- -----------------------------------------------------------------------
    -- Board error messages (board.lua)
    -- -----------------------------------------------------------------------
    ["Clear the cell before adding notes."] = { fr = "Effacez la case avant d'ajouter des notes." },
    ["Hide solution to keep playing."]      = { fr = "Masquez la solution pour continuer à jouer." },
    ["No cell selected."]                   = { fr = "Aucune case sélectionnée." },
    ["Select a white cell."]                = { fr = "Sélectionnez une case blanche." },

    -- -----------------------------------------------------------------------
    -- Note mode status
    -- -----------------------------------------------------------------------
    ["Note mode enabled."]   = { fr = "Mode notes activé." },
    ["Note mode disabled."]  = { fr = "Mode notes désactivé." },
    ["Note mode is ON."]     = { fr = "Mode notes : ACTIF." },

    -- -----------------------------------------------------------------------
    -- Word games (Boggle, Anagram, Wordle, Wordsearch, Hangman, Cryptogram)
    -- -----------------------------------------------------------------------
    ["Not a word: %1"]                    = { fr = "Pas un mot : %1" },
    ["Not in word list!"]                 = { fr = "Absent de la liste de mots !" },
    ["Word too short!"]                   = { fr = "Mot trop court !" },
    ["Word too short (min 3 letters)"]    = { fr = "Mot trop court (minimum 3 lettres)" },
    ["Not enough letters!"]               = { fr = "Pas assez de lettres !" },
    ["Found: %1!"]                        = { fr = "Trouvé : %1 !" },
    ["Found: %1 (+%2 pts)"]               = { fr = "Trouvé : %1 (+%2 pts)" },
    ["Found: %1/%2 words"]                = { fr = "Trouvé : %1/%2 mots" },
    ["No words found yet."]               = { fr = "Aucun mot trouvé pour l'instant." },
    ["Already found: %1"]                 = { fr = "Déjà trouvé : %1" },
    ["No match. Try again."]              = { fr = "Pas de correspondance. Réessayez." },
    ["You won in %1 attempt(s)!"]         = { fr = "Vous avez gagné en %1 tentative(s) !" },
    ["Not solved yet."]                   = { fr = "Pas encore résolu." },
    ["Try %1/%2: %3"]                     = { fr = "Tentative %1/%2 : %3" },
    ["Try %1/%2  W:%3 L:%4"]             = { fr = "Tentative %1/%2  V:%3 D:%4" },
    ["Lost! Word: %1  W:%2 L:%3"]         = { fr = "Perdu ! Mot : %1  V:%2 D:%3" },
    ["You won! W:%1 L:%2"]                = { fr = "Vous avez gagné ! V:%1 D:%2" },
    ["Wrong! The word was: %1  Losses: %2"] = { fr = "Faux ! Le mot était : %1  Défaites : %2" },
    ["Wrong: %1/%2  W:%3 L:%4"]           = { fr = "Faux : %1/%2  V:%3 D:%4" },
    ["Missed: %1"]                        = { fr = "Manqué : %1" },
    ["Word: %1  Score: %2  Found: %3"]    = { fr = "Mot : %1  Score : %2  Trouvé : %3" },
    ["Score: %1  Found: %2/%3"]           = { fr = "Score : %1  Trouvé : %2/%3" },
    ["Decoded: %1/%2 letters"]            = { fr = "Déchiffré : %1/%2 lettres" },
    ["Selected: %1  Decoded: %2/%3"]      = { fr = "Sélectionné : %1  Déchiffré : %2/%3" },
    ["Selected: %1 = %2  Decoded: %3/%4"] = { fr = "Sélectionné : %1 = %2  Déchiffré : %3/%4" },
    ["Entering: %1 (tap another digit or Erase)"] = { fr = "Saisie : %1 (autre chiffre ou Effacer)" },
    ["Attempt %1/%2 — slot %3 selected"]  = { fr = "Tentative %1/%2 — case %3 sélectionnée" },
    ["Fill all slots before submitting."] = { fr = "Remplissez toutes les cases avant de valider." },
    ["Errors: %1"]                        = { fr = "Erreurs : %1" },
    ["Score: %1 \xC2\xB7 Best: %2 \xC2\xB7 Max: %3"] = { fr = "Score : %1 · Meilleur : %2 · Max : %3" },

    -- -----------------------------------------------------------------------
    -- 2048
    -- -----------------------------------------------------------------------
    ["You reached 2048! Keep going!"]      = { fr = "Vous avez atteint 2048 ! Continuez !" },
    ["Game over \xC2\xB7 Score: %1 \xC2\xB7 Best: %2"] = { fr = "Partie terminée · Score : %1 · Meilleur : %2" },

    -- -----------------------------------------------------------------------
    -- Battleship
    -- -----------------------------------------------------------------------
    ["Ships: %1/%2  Tap=cycle  Hold=water"] = { fr = "Navires : %1/%2  App.=cycle  Maintien=eau" },

    -- -----------------------------------------------------------------------
    -- Bridges / Islands
    -- -----------------------------------------------------------------------
    ["Island selected: needs %1 bridges"]  = { fr = "Île sélectionnée : %1 pont(s) requis" },
    ["Islands satisfied: %1/%2"]           = { fr = "Îles satisfaites : %1/%2" },
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 %4/%5 islands done"] = { fr = "%1×%2 · %3 · %4/%5 îles terminées" },

    -- -----------------------------------------------------------------------
    -- Cryptogram
    -- -----------------------------------------------------------------------
    ["Selected: %1,%2  \xC2\xB7  Empty cells: %3"] = { fr = "Sélection : %1,%2  ·  Cases vides : %3" },

    -- -----------------------------------------------------------------------
    -- Fillomino
    -- -----------------------------------------------------------------------
    ["Value %1 out of range (1-%2)."] = { fr = "Valeur %1 hors plage (1-%2)." },

    -- -----------------------------------------------------------------------
    -- Galaxies
    -- -----------------------------------------------------------------------
    ["%1\xC3\x97%2 \xC2\xB7 %3 galaxies \xC2\xB7 Unassigned: %4"] = { fr = "%1×%2 · %3 galaxies · Non assignées : %4" },

    -- -----------------------------------------------------------------------
    -- Kakuro
    -- -----------------------------------------------------------------------
    -- (Across/Down already above)

    -- -----------------------------------------------------------------------
    -- Lightup / Lit
    -- -----------------------------------------------------------------------
    ["Lit: %1/%2  Bulbs: %3  Tap=cycle  Hold=dot"] = { fr = "Éclairées : %1/%2  Ampoules : %3  App.=cycle  Maintien=point" },

    -- -----------------------------------------------------------------------
    -- Masyu
    -- -----------------------------------------------------------------------
    ["Circles on path: %1/%2  \xC2\xB7  Path cells: %3"] = { fr = "Cercles sur le tracé : %1/%2  ·  Cases du tracé : %3" },

    -- -----------------------------------------------------------------------
    -- Memory
    -- -----------------------------------------------------------------------
    ["Pairs: %1/%2 \xC2\xB7 Empty cells: %3"] = { fr = "Paires : %1/%2 · Cases vides : %3" },

    -- -----------------------------------------------------------------------
    -- Minesweeper
    -- -----------------------------------------------------------------------
    ["Mines: %1 \xC2\xB7 Time: %2%3"]  = { fr = "Mines : %1 · Temps : %2%3" },
    ["Safe cells remaining: %1"]        = { fr = "Cases sûres restantes : %1" },

    -- -----------------------------------------------------------------------
    -- Nonogram / Color Nonogram
    -- -----------------------------------------------------------------------
    ["Shaded: %1"] = { fr = "Noircies : %1" },
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Shaded: %4/%5 \xC2\xB7 Clues: %6"] = { fr = "%1×%2 · %3 · Noircies : %4/%5 · Indices : %6" },
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Filled: %4/%5"] = { fr = "%1×%2 · %3 · Remplies : %4/%5" },

    -- -----------------------------------------------------------------------
    -- Numberlink
    -- -----------------------------------------------------------------------
    ["Selected (%1,%2) — tap adjacent cell to connect."] = { fr = "Sélectionné (%1,%2) — appuyez sur une case adjacente pour connecter." },

    -- -----------------------------------------------------------------------
    -- Numbrix / Hidato
    -- -----------------------------------------------------------------------
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Empty: %4"] = { fr = "%1×%2 · %3 · Vides : %4" },
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Empty: %4%5%6"] = { fr = "%1×%2 · %3 · Vides : %4%5%6" },
    ["  \xC2\xB7 Empty: %1"]           = { fr = "  · Vides : %1" },
    [" \xC2\xB7 Flag ON"]              = { fr = " · Drapeau ON" },
    [" \xC2\xB7 Note ON"]              = { fr = " · Notes ON" },
    [" · Note ON"]                     = { fr = " · Notes ON" },

    -- -----------------------------------------------------------------------
    -- Pickomino (dice game)
    -- -----------------------------------------------------------------------
    ["Need at least one worm and total >= 21 to stop."] = { fr = "Il faut au moins un ver et un total ≥ 21 pour s'arrêter." },
    ["Cannot keep %1 — already set aside or not rolled."] = { fr = "Impossible de garder %1 — déjà mis de côté ou non lancé." },
    ["Keep a die face first."]           = { fr = "Gardez d'abord une face de dé." },
    ["Nothing to stop yet. Roll first."] = { fr = "Rien à arrêter. Lancez d'abord." },
    ["Roll the dice first."]             = { fr = "Lancez les dés d'abord." },
    ["Choose a face to keep"]            = { fr = "Choisissez une face à garder" },
    ["Bust! No new values available."]   = { fr = "Banqueroute ! Aucune nouvelle valeur disponible." },
    ["Round %1/%2 | Sum: %3%4 | Score: %5 | %6"] = { fr = "Tour %1/%2 | Somme : %3%4 | Score : %5 | %6" },
    ["Cannot keep %1 — already set aside or not rolled."] = { fr = "Impossible de garder %1 — déjà mis de côté ou non lancé." },

    -- -----------------------------------------------------------------------
    -- Shikaku / Rectangles
    -- -----------------------------------------------------------------------
    ["Rectangle area must equal the clue number."] = { fr = "L'aire du rectangle doit égaler le chiffre indice." },
    ["Rectangle is outside the grid."]             = { fr = "Le rectangle dépasse de la grille." },
    ["Rectangle must contain exactly one clue."]   = { fr = "Le rectangle doit contenir exactement un indice." },
    ["Rectangles cannot overlap."]                 = { fr = "Les rectangles ne peuvent pas se chevaucher." },
    ["Cannot place rectangle here."]               = { fr = "Impossible de placer un rectangle ici." },
    ["Rectangles placed: %1/%2 — keep going!"]     = { fr = "Rectangles placés : %1/%2 — continuez !" },
    [" \xC2\xB7 Tap second corner"]               = { fr = " · Appuyez sur le second coin" },
    [" \xC2\xB7 Tap two corners to place"]        = { fr = " · Appuyez sur deux coins pour placer" },
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Rects: %4/%5%6"] = { fr = "%1×%2 · %3 · Rectangles : %4/%5%6" },

    -- -----------------------------------------------------------------------
    -- Slitherlink / Masyu (loop / edges)
    -- -----------------------------------------------------------------------
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Edges left: %4"] = { fr = "%1×%2 · %3 · Arêtes restantes : %4" },

    -- -----------------------------------------------------------------------
    -- Sokoban
    -- -----------------------------------------------------------------------
    ["Boxes: %1/%2  Moves: %3  Pushes: %4"] = { fr = "Caisses : %1/%2  Déplacements : %3  Poussées : %4" },
    ["Level %1 complete! Moves: %2"]         = { fr = "Niveau %1 terminé ! Déplacements : %2" },
    ["Moves: %1  Time: %2  Best: %3"]        = { fr = "Déplacements : %1  Temps : %2  Meilleur : %3" },
    ["Moves: %1 / Optimal: %2"]             = { fr = "Déplacements : %1 / Optimal : %2" },

    -- -----------------------------------------------------------------------
    -- Star Battle
    -- -----------------------------------------------------------------------
    ["%1\xC3\x97%2 \xC2\xB7 %3\xE2\x98\x85/row \xC2\xB7 Stars: %4/%5"] = { fr = "%1×%2 · %3★/ligne · Étoiles : %4/%5" },

    -- -----------------------------------------------------------------------
    -- Tents
    -- -----------------------------------------------------------------------
    ["Tents: %1/%2  Tap=cycle  Long=grass"] = { fr = "Tentes : %1/%2  App.=cycle  Long=herbe" },

    -- -----------------------------------------------------------------------
    -- Hanoi
    -- -----------------------------------------------------------------------
    ["%1 disks"]                     = { fr = "%1 disques" },
    [" — Peg %1 selected"]           = { fr = " — Tige %1 sélectionnée" },

    -- -----------------------------------------------------------------------
    -- Fifteen (sliding puzzle)
    -- -----------------------------------------------------------------------
    -- No game-specific strings beyond common ones

    -- -----------------------------------------------------------------------
    -- Gomoku / Othello (player-specific messages already in FR for some)
    -- -----------------------------------------------------------------------
    ["Wins: %1  Losses: %2"]         = { fr = "Victoires : %1  Défaites : %2" },
    ["%1/%2"]                        = { fr = "%1/%2" },

    -- -----------------------------------------------------------------------
    -- Cave / Path games
    -- -----------------------------------------------------------------------
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Unknown: %4"] = { fr = "%1×%2 · %3 · Inconnues : %4" },

    -- -----------------------------------------------------------------------
    -- KenKen / Cages
    -- -----------------------------------------------------------------------
    ["%1 (%2 cages)"]                = { fr = "%1 (%2 cages)" },
    ["  \xC2\xB7 Cage: %1/%2 cells, sum %3/%4"] = { fr = "  · Cage : %1/%2 cases, somme %3/%4" },

    -- -----------------------------------------------------------------------
    -- Bridges / Dominoes
    -- -----------------------------------------------------------------------
    ["%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Dominoes: %4/%5"] = { fr = "%1×%2 · %3 · Dominos : %4/%5" },

    -- -----------------------------------------------------------------------
    -- Settings dialogs (game-common/settings_dialog.lua)
    -- -----------------------------------------------------------------------
    ["Select"]         = { fr = "Sélectionner" },
    ["Nothing to undo."] = { fr = "Rien à annuler." },

    -- -----------------------------------------------------------------------
    -- Mastermind
    -- -----------------------------------------------------------------------
    ["Mastermind — Settings"]  = { fr = "Mastermind — Réglages" },

    -- -----------------------------------------------------------------------
    -- Generic settings / skeleton placeholders (remove in real plugins)
    -- -----------------------------------------------------------------------
    ["My Game v1.0"]          = { fr = "Mon Jeu v1.0" },
    ["My Game — Settings"]    = { fr = "Mon Jeu — Réglages" },

    -- -----------------------------------------------------------------------
    -- Dashboard
    -- -----------------------------------------------------------------------
    ["Dashboard"]                            = { fr = "Tableau de bord" },
    ["Open Dashboard"]                       = { fr = "Ouvrir le Dashboard" },
    ["Show at startup"]                      = { fr = "Afficher au démarrage" },
    ["Startup delay: %1 s"]                  = { fr = "Délai au démarrage : %1 s" },
    ["Home button → Dashboard"]              = { fr = "Bouton Home → Dashboard" },
    ["Reading"]                              = { fr = "Lecture" },
    ["Recent games"]                         = { fr = "Derniers jeux" },
    ["Play stats"]                           = { fr = "Statistiques de jeu" },
    ["Actions"]                              = { fr = "Actions" },
    ["No reading history."]                  = { fr = "Aucun historique de lecture." },
    ["No games played yet."]                 = { fr = "Aucun jeu joué pour l'instant." },
    ["Books: %1"]                            = { fr = "Livres : %1" },
    ["Plugins installed: %1 — played: %2"]   = { fr = "Jeux installés : %1 — joués : %2" },
    ["Update plugins"]                       = { fr = "MAJ plugins" },
    ["Library"]                              = { fr = "Bibliothèque" },
    ["just now"]                             = { fr = "à l'instant" },
    ["%1 min"]                               = { fr = "%1 min" },
    ["%1 h"]                                 = { fr = "%1 h" },
    ["%1 d"]                                 = { fr = "%1 j" },
    ["%1 sessions · %2"]                     = { fr = "%1 parties · %2" },
    ["Time: %1"]                             = { fr = "Durée : %1" },
    ["No stats yet."]                        = { fr = "Aucune statistique pour l'instant." },

    -- -----------------------------------------------------------------------
    -- Binairo
    -- -----------------------------------------------------------------------
    ["Binairo"]                              = { fr = "Binairo" },
    ["Binairo — Settings"]                   = { fr = "Binairo — Réglages" },
    ["Empty: %1"]                            = { fr = "Vides : %1" },
    ["Solved! Time: %1"]                     = { fr = "Résolu ! Temps : %1" },
    ["%1 error(s) highlighted."]             = { fr = "%1 erreur(s) mise(s) en évidence." },

    -- -----------------------------------------------------------------------
    -- Misc status messages
    -- -----------------------------------------------------------------------
    ["Remaining: %1  |  Mode: %2"]   = { fr = "Restantes : %1  |  Mode : %2" },
    ["%1/%2  %3"]                    = { fr = "%1/%2  %3" },
    ["%1/%2 — %3"]                   = { fr = "%1/%2 — %3" },
    [" | L:%1 R:%2"]                 = { fr = " | G:%1 D:%2" },
    ["%1/%2"]                        = { fr = "%1/%2" },
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function translate(s)
    local l = lang()
    if l ~= "en" then
        local entry = S[s]
        if entry and entry[l] then return entry[l] end
    end
    return koreader_t(s)
end

-- Allow `local _ = require("i18n")` — callable as _("string")
-- Also expose:  require("i18n").lang()   — current 2-letter language code
return setmetatable({ lang = lang }, {
    __call = function(_, s) return translate(s) end,
})
