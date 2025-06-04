import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async'; // For Timer
import 'package:intl/intl.dart'; // For date formatting
import 'package:google_mobile_ads/google_mobile_ads.dart'; // Import for Google Mobile Ads
// Import for platform-specific ad unit IDs

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Google Mobile Ads SDK
  MobileAds.instance.initialize();
  print("DEBUG: \u2705 Google Mobile Ads initialized successfully");

  try {
    await Firebase.initializeApp();
    print("DEBUG: \u2705 Firebase initialized successfully");
  } catch (e) {
    print("DEBUG: \u274C Firebase failed to initialize: $e");
    // In a production app, you might want to show a user-friendly error message
    // or log this error to a crash reporting service.
  }

  runApp(const FocusNotesApp());
}

class FocusNotesApp extends StatelessWidget {
  const FocusNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FocusNotes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E88E5), // Deep Blue 700
          brightness: Brightness.dark, // Dark theme for the app
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E88E5), // Deep Blue 700
          foregroundColor: Colors.white, // White text/icons on AppBar
        ),
        scaffoldBackgroundColor: const Color(0xFF212121), // Grey 900
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF1E88E5), // Deep Blue 700
          foregroundColor: Colors.white, // White icon on FAB
        ),
        drawerTheme: const DrawerThemeData(
          backgroundColor: Color(0xFF212121), // Grey 900
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white70),
          headlineSmall: TextStyle(color: Colors.white),
          titleMedium: TextStyle(color: Colors.white),
          labelLarge: TextStyle(color: Colors.white),
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: Colors.white70,
          textColor: Colors.white,
          selectedTileColor: Color(
            0xFF303030,
          ), // Slightly lighter grey for selected items
        ),
      ),
      home: const NotesScreen(), // The main screen of the application
    );
  }
}

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  // Global key to control the Scaffold (e.g., open/close drawer).
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // State variables to manage the current view/category of notes.
  String _currentTitle = 'All Notes';
  String _currentCategory = 'all'; // 'all', 'favorites', 'reminders', 'trash'
  // Controller for the search input field.
  final TextEditingController _searchController = TextEditingController();
  // Flag to control visibility of the search input.
  bool _showSearchInput = false;
  // Timer for checking reminders periodically.
  Timer? _reminderCheckTimer;
  // Content of the note for which a reminder is triggered.
  String? _reminderNoteContent;
  // Flag to show/hide the reminder alert dialog.
  bool _showReminderAlert = false;

  // Application ID used for Firestore collection paths.
  // In a real-world scenario, this might be dynamically configured.
  final String _appId = 'default-app-id';

  // Current authenticated Firebase user.
  User? _currentUser;
  // Reference to the Firestore collection where notes are stored.
  CollectionReference? _notesCollection;

  // StreamSubscription to listen for authentication state changes.
  StreamSubscription<User?>? _authStateSubscription;

  // AdMob Banner Ad variables
  BannerAd? _bannerAd;
  bool _isBannerAdLoaded = false;
  final AdSize _adSize = AdSize.banner; // Standard banner ad size

  @override
  void initState() {
    super.initState();
    _initializeAuthAndCollection();
    _loadBannerAd(); // Load the banner ad when the screen initializes

    // Listen for authentication state changes.
    // This ensures the app reacts to user sign-in/sign-out events.
    _authStateSubscription = FirebaseAuth.instance.authStateChanges().listen((
      user,
    ) {
      if (user != null) {
        print("DEBUG: Auth State Changed - User is signed in: ${user.uid}");
        // If the user changes (e.g., from anonymous to a different anonymous user),
        // re-initialize the collection and restart the reminder timer.
        if (_currentUser?.uid != user.uid) {
          setState(() {
            _currentUser = user;
            _notesCollection = FirebaseFirestore.instance.collection(
              'artifacts/$_appId/users/${_currentUser!.uid}/notes',
            );
            print(
              "DEBUG: Notes collection re-initialized for user: ${_notesCollection?.path}",
            );
          });
          _startReminderCheckTimer();
        }
      } else {
        print("DEBUG: Auth State Changed - User is signed out.");
        // If the user signs out, clear the current user and notes collection.
        setState(() {
          _currentUser = null;
          _notesCollection = null; // Clear collection if signed out
        });
        _reminderCheckTimer?.cancel(); // Stop reminder checks if no user
      }
    });

    // Add a listener to the search controller to trigger UI updates when text changes.
    _searchController.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    // Cancel the reminder timer to prevent memory leaks.
    _reminderCheckTimer?.cancel();
    // Dispose the search controller to release resources.
    _searchController.dispose();
    // Cancel the authentication state subscription.
    _authStateSubscription?.cancel();
    // Dispose the banner ad to prevent memory leaks.
    _bannerAd?.dispose();
    super.dispose();
  }

  // Initializes Firebase authentication and sets up the Firestore collection.
  Future<void> _initializeAuthAndCollection() async {
    print("DEBUG: _initializeAuthAndCollection called.");

    // Check if Firebase is already initialized.
    // This is a safeguard, as it should typically be initialized in `main`.
    if (Firebase.apps.isEmpty) {
      print(
        "DEBUG: Firebase not initialized, attempting again in _initializeAuthAndCollection.",
      );
      try {
        await Firebase.initializeApp();
        print(
          "DEBUG: \u2705 Firebase initialized successfully within _initializeAuthAndCollection",
        );
      } catch (e) {
        print(
          "DEBUG: \u274C Firebase failed to initialize within _initializeAuthAndCollection: $e",
        );
        return;
      }
    }

    // Attempt to sign in anonymously if no user is currently signed in.
    if (FirebaseAuth.instance.currentUser == null) {
      print("DEBUG: No current user, attempting anonymous sign-in...");
      try {
        UserCredential userCredential = await FirebaseAuth.instance
            .signInAnonymously();
        _currentUser = userCredential.user;
        print("DEBUG: Signed in anonymously. User UID: ${_currentUser?.uid}");
      } on FirebaseAuthException catch (e) {
        if (e.code == 'operation-not-allowed') {
          print(
            "DEBUG: Anonymous auth not enabled. Enable it in your Firebase console under Authentication -> Sign-in method.",
          );
        } else {
          print("DEBUG: Error during anonymous sign-in: $e");
        }
        // In a production app, you would provide user feedback here.
        return;
      } catch (e) {
        print("DEBUG: Generic error during anonymous sign-in: $e");
        return;
      }
    } else {
      _currentUser = FirebaseAuth.instance.currentUser;
      print("DEBUG: Already signed in. User UID: ${_currentUser?.uid}");
    }

    // If a user is authenticated, set up the Firestore collection reference.
    if (_currentUser != null) {
      setState(() {
        _notesCollection = FirebaseFirestore.instance.collection(
          'artifacts/$_appId/users/${_currentUser!.uid}/notes',
        );
        print("DEBUG: Notes collection path set to: ${_notesCollection?.path}");
      });
      // Start the reminder check timer once the collection is ready.
      _startReminderCheckTimer();
    } else {
      print(
        "DEBUG: User not authenticated after sign-in attempt. Cannot set up notes collection.",
      );
    }
  }

  // Loads a banner ad.
  void _loadBannerAd() {
    // Use the provided banner ad unit ID.
    // If you have separate ad unit IDs for Android and iOS, you can use Platform.isAndroid / Platform.isIOS
    // to differentiate them. For now, using the single provided ID for both.
    String adUnitId =
        'ca-app-pub-1103134131518290/8509915913'; // Your provided banner ad unit ID

    _bannerAd = BannerAd(
      adUnitId: adUnitId, // Use your provided banner ad unit ID
      size: _adSize,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          setState(() {
            _isBannerAdLoaded = true;
          });
          print("DEBUG: Banner ad loaded successfully.");
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          print("DEBUG: Banner ad failed to load: $error");
          setState(() {
            _isBannerAdLoaded = false;
          });
        },
        onAdOpened: (ad) => print("DEBUG: Banner ad opened."),
        onAdClosed: (ad) => print("DEBUG: Banner ad closed."),
      ),
    )..load();
  }

  // Starts a periodic timer to check for upcoming reminders.
  void _startReminderCheckTimer() {
    // Cancel any existing timer to prevent multiple timers running.
    _reminderCheckTimer?.cancel();
    if (_notesCollection == null) {
      print("DEBUG: Cannot start reminder timer, _notesCollection is null.");
      return;
    }

    // Set up a periodic timer that fires every 5 seconds.
    _reminderCheckTimer = Timer.periodic(const Duration(seconds: 5), (
      timer,
    ) async {
      final now = DateTime.now();
      try {
        // Query Firestore for notes with reminders that are due and not yet reminded.
        final snapshot = await _notesCollection!
            .where(
              'reminderTimestamp',
              isLessThanOrEqualTo: Timestamp.fromDate(now),
            )
            .where('reminded', isEqualTo: false)
            .get();

        if (snapshot.docs.isNotEmpty) {
          print("DEBUG: Found ${snapshot.docs.length} reminders to show.");
        }

        // Iterate through found reminders and display them.
        for (var doc in snapshot.docs) {
          final noteContent =
              (doc.data() as Map<String, dynamic>)['content'] ?? 'No content';
          setState(() {
            _reminderNoteContent = noteContent;
            _showReminderAlert = true; // Show the reminder dialog
          });
          // Mark the reminder as 'reminded' in Firestore to prevent repeated alerts.
          await _notesCollection!.doc(doc.id).update({'reminded': true});
          print(
            "DEBUG: Reminder shown and marked as reminded for note: ${doc.id}",
          );
        }
      } catch (e) {
        print("DEBUG: Error checking reminders: $e");
      }
    });
  }

  // Updates the app bar title and the current note category.
  void _updateTitleAndCategory(String newTitle, String newCategory) {
    setState(() {
      _currentTitle = newTitle;
      _currentCategory = newCategory;
      _showSearchInput = false; // Hide search input when changing category
      _searchController.clear(); // Clear search text
    });
    Navigator.pop(context); // Close the drawer
  }

  // Shows a dialog for adding a new note or editing an existing one.
  void _showNoteDialog({DocumentSnapshot? noteToEdit}) async {
    if (_notesCollection == null) {
      print("DEBUG: Notes collection not initialized. Cannot show dialog.");
      // Provide user feedback if Firestore is not ready.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App is still loading. Please wait.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Initialize content controller with existing note content if editing.
    final TextEditingController contentController = TextEditingController(
      text: noteToEdit != null
          ? (noteToEdit.data() as Map<String, dynamic>)['content']
          : '',
    );
    DateTime? selectedDate;
    TimeOfDay? selectedTime;

    // If editing, pre-fill reminder date and time if available.
    if (noteToEdit != null &&
        (noteToEdit.data() as Map<String, dynamic>)['reminderTimestamp'] !=
            null) {
      final Timestamp reminderTs =
          (noteToEdit.data() as Map<String, dynamic>)['reminderTimestamp'];
      final DateTime reminderDt = reminderTs.toDate();
      selectedDate = DateTime(
        reminderDt.year,
        reminderDt.month,
        reminderDt.day,
      );
      selectedTime = TimeOfDay.fromDateTime(reminderDt);
    }

    // Show the AlertDialog for note input.
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        // Use StatefulBuilder to update dialog UI
        builder: (context, setStateInDialog) {
          return AlertDialog(
            backgroundColor: Colors.grey[900], // Dark background for the dialog
            title: Text(
              noteToEdit != null ? 'Edit Note' : 'Add Note',
              style: const TextStyle(color: Colors.white),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: contentController,
                    autofocus: true,
                    maxLines: 5,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Write your note here...',
                      hintStyle: TextStyle(color: Colors.white54),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Date picker ListTile
                  ListTile(
                    leading: const Icon(
                      Icons.calendar_today,
                      color: Colors.white70,
                    ),
                    title: Text(
                      selectedDate == null
                          ? 'Set Date (Optional)'
                          : DateFormat.yMMMd().format(selectedDate!),
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () async {
                      final DateTime? picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate ?? DateTime.now(),
                        firstDate: DateTime.now(),
                        lastDate: DateTime(2101),
                        builder: (context, child) {
                          // Theme the date picker for dark mode consistency.
                          return Theme(
                            data: ThemeData.dark().copyWith(
                              colorScheme: const ColorScheme.dark(
                                primary: Color(
                                  0xFF1E88E5,
                                ), // Accent color for selected date
                                onPrimary: Colors.white,
                                onSurface: Colors.white, // Text color for dates
                                surface: Color(
                                  0xFF424242,
                                ), // Background of the date picker
                              ),
                              textButtonTheme: TextButtonThemeData(
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors
                                      .white, // Color for "Cancel", "OK" buttons
                                ),
                              ),
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (picked != null && picked != selectedDate) {
                        setStateInDialog(() {
                          // Update state within the dialog
                          selectedDate = picked;
                        });
                      }
                    },
                  ),
                  // Time picker ListTile
                  ListTile(
                    leading: const Icon(Icons.alarm, color: Colors.white70),
                    title: Text(
                      selectedTime == null
                          ? 'Set Time (Optional)'
                          : selectedTime!.format(context),
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () async {
                      final TimeOfDay? picked = await showTimePicker(
                        context: context,
                        initialTime: selectedTime ?? TimeOfDay.now(),
                        builder: (context, child) {
                          // Theme the time picker for dark mode consistency.
                          return Theme(
                            data: ThemeData.dark().copyWith(
                              colorScheme: const ColorScheme.dark(
                                primary: Color(
                                  0xFF1E88E5,
                                ), // Accent color for selected time
                                onPrimary: Colors.white,
                                onSurface: Colors.white, // Text color for time
                                surface: Color(
                                  0xFF424242,
                                ), // Background of the time picker
                              ),
                              textButtonTheme: TextButtonThemeData(
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors
                                      .white, // Color for "Cancel", "OK" buttons
                                ),
                              ),
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (picked != null && picked != selectedTime) {
                        setStateInDialog(() {
                          // Update state within the dialog
                          selectedTime = picked;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white70),
                ),
                onPressed: () => Navigator.pop(context),
              ),
              TextButton(
                child: Text(
                  noteToEdit != null ? 'Update' : 'Save',
                  style: const TextStyle(color: Colors.white),
                ),
                onPressed: () async {
                  final text = contentController.text.trim();
                  if (text.isNotEmpty) {
                    Timestamp? reminderTimestamp;
                    if (selectedDate != null && selectedTime != null) {
                      // Combine date and time into a single DateTime object.
                      final reminderDateTime = DateTime(
                        selectedDate!.year,
                        selectedDate!.month,
                        selectedDate!.day,
                        selectedTime!.hour,
                        selectedTime!.minute,
                      );
                      reminderTimestamp = Timestamp.fromDate(reminderDateTime);
                    }

                    if (noteToEdit != null) {
                      // Update existing note.
                      await _notesCollection!.doc(noteToEdit.id).update({
                        'content': text,
                        'reminderTimestamp': reminderTimestamp,
                        'reminded': false, // Reset reminded status on update
                      });
                      print("DEBUG: Updated note: ${noteToEdit.id}");
                    } else {
                      // Add new note.
                      await _notesCollection!.add({
                        'content': text,
                        'timestamp':
                            FieldValue.serverTimestamp(), // Firestore server timestamp
                        'category': 'all', // Default category for new notes
                        'reminderTimestamp': reminderTimestamp,
                        'reminded': false, // Not yet reminded
                        'isFavorite': false, // Not a favorite by default
                      });
                      print("DEBUG: Added new note.");
                    }
                  }
                  Navigator.pop(context); // Close the dialog
                },
              ),
            ],
          );
        },
      ),
    );
  }

  // Handles deleting a note or moving it to trash.
  void _handleDeleteNote(String noteId, String noteCategory) async {
    if (_notesCollection == null) {
      print("DEBUG: Notes collection not initialized. Cannot delete note.");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App is still loading. Please wait.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (noteCategory == 'trash') {
      // If the note is already in trash, confirm permanent deletion.
      bool? confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Confirm Deletion',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Are you sure you want to permanently delete this note? This action cannot be undone.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false), // Cancel
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white70),
              ),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(true), // Confirm permanent delete
              child: const Text(
                'Delete Permanently',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      );
      if (confirm == true) {
        await _notesCollection!.doc(noteId).delete(); // Perform actual deletion
        print("DEBUG: Permanently deleted note: $noteId");
      }
    } else {
      // If not in trash, move the note to the 'trash' category.
      await _notesCollection!.doc(noteId).update({'category': 'trash'});
      print("DEBUG: Moved note to trash: $noteId");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey, // Assign the global key to the Scaffold
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu), // Drawer icon
          onPressed: () =>
              _scaffoldKey.currentState?.openDrawer(), // Open the drawer
        ),
        title: _showSearchInput && _currentCategory == 'all'
            ? TextField(
                // Search input field, visible only for 'All Notes' when search is active.
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search notes...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                  prefixIcon: const Icon(Icons.search, color: Colors.white70),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white70),
                          onPressed: () =>
                              _searchController.clear(), // Clear search text
                        )
                      : null,
                ),
              )
            : Text(_currentTitle), // Display current category title
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              // Toggle search input visibility for 'All Notes' category.
              if (_currentCategory == 'all') {
                setState(() {
                  _showSearchInput = !_showSearchInput;
                  if (!_showSearchInput) {
                    _searchController.clear(); // Clear search if hiding input
                  }
                });
              }
            },
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: <Widget>[
            DrawerHeader(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFF1E88E5),
                    Color(0xFF42A5F5),
                  ], // Blue gradient
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const CircleAvatar(
                    backgroundColor: Colors.white,
                    radius: 30,
                    child: Icon(
                      Icons.architecture, // App icon
                      color: Color(0xFF1E88E5),
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'FocusNotes',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            // Drawer list tiles for different note categories.
            ListTile(
              leading: const Icon(Icons.home),
              title: const Text('All Notes'),
              selected: _currentCategory == 'all',
              onTap: () => _updateTitleAndCategory('All Notes', 'all'),
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: const Text('Favorites'),
              selected: _currentCategory == 'favorites',
              onTap: () => _updateTitleAndCategory('Favorites', 'favorites'),
            ),
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Reminders'),
              selected: _currentCategory == 'reminders',
              onTap: () => _updateTitleAndCategory('Reminders', 'reminders'),
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: const Text('Trash'),
              selected: _currentCategory == 'trash',
              onTap: () => _updateTitleAndCategory('Trash', 'trash'),
            ),
          ],
        ),
      ),
      body: _notesCollection == null
          ? const Center(
              child: CircularProgressIndicator(),
            ) // Show loading indicator if collection not ready
          : Stack(
              children: [
                StreamBuilder<QuerySnapshot>(
                  // Listen for real-time updates from Firestore.
                  stream: _notesCollection!
                      .orderBy(
                        'timestamp',
                        descending: true,
                      ) // Order notes by creation time
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (snapshot.hasError) {
                      print("DEBUG: StreamBuilder Error: ${snapshot.error}");
                      return Center(
                        child: Text(
                          'Error: ${snapshot.error}',
                          style: const TextStyle(color: Colors.red),
                        ),
                      );
                    }

                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      // Display message if no notes are found.
                      return Center(
                        child: Text(
                          _searchController.text.isNotEmpty &&
                                  _currentCategory == 'all'
                              ? 'No notes found matching "${_searchController.text}".'
                              : 'No notes yet in this category.',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      );
                    }

                    List<DocumentSnapshot> notes = snapshot.data!.docs;

                    // Filter notes based on the currently selected category.
                    if (_currentCategory == 'all') {
                      notes = notes
                          .where(
                            (note) =>
                                (note.data()
                                    as Map<String, dynamic>)['category'] !=
                                'trash',
                          )
                          .toList();
                    } else if (_currentCategory == 'favorites') {
                      notes = notes
                          .where(
                            (note) =>
                                (note.data()
                                    as Map<String, dynamic>)['isFavorite'] ==
                                true,
                          )
                          .toList();
                    } else if (_currentCategory == 'reminders') {
                      notes = notes
                          .where(
                            (note) =>
                                (note.data()
                                        as Map<
                                          String,
                                          dynamic
                                        >)['reminderTimestamp'] !=
                                    null &&
                                (note.data()
                                        as Map<String, dynamic>)['category'] !=
                                    'trash',
                          )
                          .toList();
                    } else if (_currentCategory == 'trash') {
                      notes = notes
                          .where(
                            (note) =>
                                (note.data()
                                    as Map<String, dynamic>)['category'] ==
                                'trash',
                          )
                          .toList();
                    }

                    // Apply search filter if in 'All Notes' and search text is present.
                    if (_currentCategory == 'all' &&
                        _searchController.text.isNotEmpty) {
                      final searchTermLower = _searchController.text
                          .toLowerCase();
                      notes = notes.where((note) {
                        final content =
                            (note.data() as Map<String, dynamic>)['content']
                                ?.toLowerCase() ??
                            '';
                        return content.contains(searchTermLower);
                      }).toList();
                      // Optionally sort search results to show matching notes first.
                      notes.sort((a, b) {
                        final aMatches =
                            ((a.data() as Map<String, dynamic>)['content']
                                        ?.toLowerCase() ??
                                    '')
                                .contains(searchTermLower);
                        final bMatches =
                            ((b.data() as Map<String, dynamic>)['content']
                                        ?.toLowerCase() ??
                                    '')
                                .contains(searchTermLower);
                        if (aMatches && !bMatches) return -1;
                        if (!aMatches && bMatches) return 1;
                        return 0;
                      });
                    }

                    return ListView.builder(
                      // Add padding to the bottom of the ListView to prevent content from being
                      // obscured by the ad banner. The height of a standard banner is 50 dp.
                      padding: EdgeInsets.fromLTRB(
                        16.0,
                        16.0,
                        16.0,
                        16.0 + _adSize.height,
                      ),
                      itemCount: notes.length,
                      itemBuilder: (context, index) {
                        final note = notes[index];
                        final Map<String, dynamic> noteData =
                            note.data() as Map<String, dynamic>;
                        final content = noteData['content'] ?? '';
                        final Timestamp? reminderTs =
                            noteData['reminderTimestamp'];
                        final DateTime? reminderDt = reminderTs?.toDate();
                        final bool isFavorite = noteData['isFavorite'] ?? false;

                        return Card(
                          color: const Color(
                            0xFF424242,
                          ), // Dark grey card background
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              12,
                            ), // Rounded corners for cards
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  content,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                                if (reminderDt != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Text(
                                      'Reminder: ${DateFormat.yMMMd().add_jm().format(reminderDt)}',
                                      style: const TextStyle(
                                        color: Colors.blueAccent,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                if (noteData['timestamp'] != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4.0),
                                    child: Text(
                                      'Created: ${DateFormat.yMMMd().add_jm().format((noteData['timestamp'] as Timestamp).toDate())}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                Align(
                                  alignment: Alignment.bottomRight,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Favorite button
                                      IconButton(
                                        icon: Icon(
                                          isFavorite
                                              ? Icons.star
                                              : Icons.star_border,
                                          color: isFavorite
                                              ? Colors.yellow[700]
                                              : Colors.white70,
                                        ),
                                        onPressed: () async {
                                          await _notesCollection!
                                              .doc(note.id)
                                              .update({
                                                'isFavorite': !isFavorite,
                                              });
                                          print(
                                            "DEBUG: Toggled favorite for note: ${note.id}, now: ${!isFavorite}",
                                          );
                                        },
                                      ),
                                      // Edit button
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit,
                                          color: Colors.white70,
                                        ),
                                        onPressed: () =>
                                            _showNoteDialog(noteToEdit: note),
                                      ),
                                      // Delete/Move to Trash button
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete,
                                          color: Colors.white70,
                                        ),
                                        onPressed: () => _handleDeleteNote(
                                          note.id,
                                          noteData['category'],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
                if (_showReminderAlert)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black54, // Semi-transparent overlay
                      child: Center(
                        child: AlertDialog(
                          backgroundColor: Colors
                              .blue[800], // Blue background for reminder alert
                          title: const Text(
                            '🔔 Reminder!',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          content: Text(
                            _reminderNoteContent ?? 'You have a new reminder!',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _showReminderAlert = false; // Hide the alert
                                  _reminderNoteContent = null; // Clear content
                                });
                              },
                              child: const Text(
                                'Got it!',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
      // Floating action button to add new notes.
      // Wrapped in Padding to shift it up.
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
          bottom: _adSize.height + 10.0,
        ), // Adjust to be above the ad
        child: FloatingActionButton(
          onPressed: _showNoteDialog, // Call the dialog to add a new note
          child: const Icon(Icons.add),
        ),
      ),
      floatingActionButtonLocation:
          FloatingActionButtonLocation.endFloat, // Keeps it at the end (right)
      // Add the Banner Ad to the bottomNavigationBar
      bottomNavigationBar: _isBannerAdLoaded
          ? SizedBox(
              width: _adSize.width.toDouble(),
              height: _adSize.height.toDouble(),
              child: AdWidget(ad: _bannerAd!),
            )
          : Container(
              height: _adSize.height
                  .toDouble(), // Maintain space even if ad not loaded
              color: Colors.black, // Placeholder background
              alignment: Alignment.center,
              child: const Text(
                'Loading Ad...',
                style: TextStyle(color: Colors.white70),
              ),
            ),
    );
  }
}
