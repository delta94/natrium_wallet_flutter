import 'dart:convert';
import 'dart:io';
import 'package:kalium_wallet_flutter/ui/widgets/kalium_simpledialog.dart';
import 'package:logging/logging.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share/share.dart';
import 'package:file_picker/file_picker.dart';
import 'package:kalium_wallet_flutter/appstate_container.dart';
import 'package:kalium_wallet_flutter/colors.dart';
import 'package:kalium_wallet_flutter/localization.dart';
import 'package:kalium_wallet_flutter/dimens.dart';
import 'package:kalium_wallet_flutter/styles.dart';
import 'package:kalium_wallet_flutter/kalium_icons.dart';
import 'package:kalium_wallet_flutter/bus/rxbus.dart';
import 'package:kalium_wallet_flutter/model/address.dart';
import 'package:kalium_wallet_flutter/model/authentication_method.dart';
import 'package:kalium_wallet_flutter/model/available_currency.dart';
import 'package:kalium_wallet_flutter/model/vault.dart';
import 'package:kalium_wallet_flutter/model/db/contact.dart';
import 'package:kalium_wallet_flutter/model/db/kaliumdb.dart';
import 'package:kalium_wallet_flutter/ui/settings/backupseed_sheet.dart';
import 'package:kalium_wallet_flutter/ui/contacts/add_contact.dart';
import 'package:kalium_wallet_flutter/ui/contacts/contact_details.dart';
import 'package:kalium_wallet_flutter/ui/settings/changerepresentative_sheet.dart';
import 'package:kalium_wallet_flutter/ui/settings/settings_list_item.dart';
import 'package:kalium_wallet_flutter/ui/widgets/buttons.dart';
import 'package:kalium_wallet_flutter/ui/widgets/dialog.dart';
import 'package:kalium_wallet_flutter/ui/widgets/security.dart';
import 'package:kalium_wallet_flutter/ui/util/ui_util.dart';
import 'package:kalium_wallet_flutter/util/sharedprefsutil.dart';
import 'package:kalium_wallet_flutter/util/biometrics.dart';

class SettingsSheet extends StatefulWidget {
  _SettingsSheetState createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> with TickerProviderStateMixin {
  AnimationController _controller;
  Animation<Offset> _offsetFloat; 

  final log = Logger("SettingsSheet");
  var _scaffoldKey = new GlobalKey<ScaffoldState>();
  bool _hasBiometrics = false;
  AuthenticationMethod _curAuthMethod =
      AuthenticationMethod(AuthMethod.BIOMETRICS);

  bool _contactsOpen;

  List<Contact> _contacts;

  bool notNull(Object o) => o != null;

  Future<void> _exportContacts() async {
    List<Contact> contacts = await DBHelper().getContacts();
    if (contacts.length == 0) {
      _scaffoldKey.currentState.showSnackBar(SnackBar(
                                        content: Text(
                                          KaliumLocalization.of(context).noContactsExport,
                                          style: KaliumStyles.TextStyleSnackbar)
                                        ));
      return;
    }
    List<Map<String, dynamic>> jsonList = List();
    contacts.forEach((contact) {
      jsonList.add(contact.toJson());
    });
    DateTime exportTime = DateTime.now();
    String filename = "kaliumcontacts_${exportTime.year}${exportTime.month}${exportTime.day}${exportTime.hour}${exportTime.minute}${exportTime.second}.txt";
    Directory baseDirectory = await getApplicationDocumentsDirectory();
    File contactsFile = File("${baseDirectory.path}/$filename");
    await contactsFile.writeAsString(json.encode(jsonList));
    Share.shareFile(contactsFile);
  }

  Future<void> _importContacts() async {
    String filePath = await FilePicker.getFilePath(type: FileType.CUSTOM, fileExtension: "txt");
    File f = File(filePath);
    if (!await f.exists()) {
      _scaffoldKey.currentState.showSnackBar(SnackBar(
                                        content: Text(
                                          KaliumLocalization.of(context).fileReadErr,
                                          style: KaliumStyles.TextStyleSnackbar)
                                        ));
      return;
    }
    try {
      String contents = await f.readAsString();
      Iterable contactsJson = json.decode(contents);
      List<Contact> contacts = List();
      List<Contact> contactsToAdd = List();
      contactsJson.forEach((contact) {
        contacts.add(Contact.fromJson(contact));
      });
      DBHelper dbHelper = DBHelper();
      for (Contact contact in contacts) {
        print(contact.name);
        if (!await dbHelper.contactExistsWithName(contact.name) &&  !await dbHelper.contactExistsWithAddress(contact.address)) {
          // Contact doesnt exist, make sure name and address are valid
          if (Address(contact.address).isValid()) {
            if (contact.name.startsWith("@") && contact.name.length <= 20) {
              contactsToAdd.add(contact);
            }
          }
        }
      }
      // Save all the new contacts and update states
      int numSaved = await dbHelper.saveContacts(contactsToAdd);
      if (numSaved > 0) {
        _updateContacts();
        RxBus.post(Contact(name:"", address:""), tag: RX_CONTACT_MODIFIED_TAG);
        _scaffoldKey.currentState.showSnackBar(SnackBar(
                                          content: Text(
                                            KaliumLocalization.of(context).contactsImportSuccess.replaceAll("%1", numSaved.toString()),
                                            style: KaliumStyles.TextStyleSnackbar)
                                          ));
      } else {
        _scaffoldKey.currentState.showSnackBar(SnackBar(
                                          content: Text(
                                            KaliumLocalization.of(context).noContactsImport,
                                            style: KaliumStyles.TextStyleSnackbar)
                                          ));        
      }
    } catch (e) {
      log.severe(e.toString());
      _scaffoldKey.currentState.showSnackBar(SnackBar(
                                        content: Text(
                                          KaliumLocalization.of(context).fileParseErr,
                                          style: KaliumStyles.TextStyleSnackbar)
                                        ));
      return;      
    }
  }

  @override
  void initState() {
    super.initState();
    _contactsOpen = false;
    // Determine if they have face or fingerprint enrolled, if not hide the setting
    BiometricUtil.hasBiometrics().then((bool hasBiometrics) {
      setState(() {
        _hasBiometrics = hasBiometrics;
      });
    });
    SharedPrefsUtil.inst.getAuthMethod().then((authMethod) {
      setState(() {
        _curAuthMethod = authMethod;
      });
    });
    _contacts = List();
    _updateContacts();
    // Contact added bus event
    RxBus.register<Contact>(tag: RX_CONTACT_ADDED_TAG).listen((contact) {
      setState(() {
        _contacts.add(contact);
        //Sort by name
        _contacts.sort((a, b) => a.name.compareTo(b.name));
      });
      // Full update which includes downloading new monKey
      _updateContacts();
    });
    // Contact removed bus event
    RxBus.register<Contact>(tag: RX_CONTACT_REMOVED_TAG).listen((contact) {
      setState(() {
        _contacts.remove(contact);
      });
    });
    // Setup animation controller
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );

    _offsetFloat = Tween<Offset>(begin: Offset.zero, end: Offset(UIUtil.drawerWidth(context) / 100, 0))
        .animate(_controller);

    _offsetFloat.addListener((){
      setState((){});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    RxBus.destroy(tag: RX_CONTACT_ADDED_TAG);
    RxBus.destroy(tag: RX_CONTACT_REMOVED_TAG);
    super.dispose();
  }

  void _updateContacts() {
    DBHelper().getContacts().then((contacts) {
      setState(() {
        _contacts = contacts;
      });
      for (Contact c in contacts) {
        // Download monKeys if not existing
        if (c.monkeyPath == null) {
          UIUtil.downloadOrRetrieveMonkey(context, c.address, MonkeySize.NORMAL).then((result) {
            DBHelper().setMonkeyForContact(c, result.path).then((success) {
              if (success) {
                c.monkeyPath = result.path;
                setState(() {
                  _contacts = contacts;
                });
              }
            });
          });
        }
      }
    });
  }

  Future<void> _authMethodDialog() async {
    switch (await showDialog<AuthMethod>(
        context: context,
        builder: (BuildContext context) {
          return KaliumSimpleDialog(
            title: Text(
              KaliumLocalization.of(context).authMethod,
              style: KaliumStyles.TextStyleDialogHeader,
            ),
            children: <Widget>[
              KaliumSimpleDialogOption(
                onPressed: () {
                  Navigator.pop(context, AuthMethod.PIN);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    KaliumLocalization.of(context).pinMethod,
                    style: KaliumStyles.TextStyleDialogOptions,
                  ),
                ),
              ),
              KaliumSimpleDialogOption(
                onPressed: () {
                  Navigator.pop(context, AuthMethod.BIOMETRICS);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    KaliumLocalization.of(context).biometricsMethod,
                    style: KaliumStyles.TextStyleDialogOptions,
                  ),
                ),
              ),
            ],
          );
        })) {
      case AuthMethod.PIN:
        SharedPrefsUtil.inst
            .setAuthMethod(AuthenticationMethod(AuthMethod.PIN))
            .then((result) {
          setState(() {
            _curAuthMethod = AuthenticationMethod(AuthMethod.PIN);
          });
        });
        break;
      case AuthMethod.BIOMETRICS:
        SharedPrefsUtil.inst
            .setAuthMethod(AuthenticationMethod(AuthMethod.BIOMETRICS))
            .then((result) {
          setState(() {
            _curAuthMethod = AuthenticationMethod(AuthMethod.BIOMETRICS);
          });
        });
        break;
    }
  }

  List<Widget> _buildCurrencyOptions() {
    List<Widget> ret = new List();
    AvailableCurrencyEnum.values.forEach((AvailableCurrencyEnum value) {
      ret.add(SimpleDialogOption(
        onPressed: () {
          Navigator.pop(context, value);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text(
            AvailableCurrency(value).getDisplayName(),
            style: KaliumStyles.TextStyleDialogOptions,
          ),
        ),
      ));
    });
    return ret;
  }

  Future<void> _currencyDialog() async {
    AvailableCurrencyEnum selection = await showKaliumDialog<AvailableCurrencyEnum>(
        context: context,
        builder: (BuildContext context) {
          return KaliumSimpleDialog(
            title: Padding(
              padding: const EdgeInsets.only(bottom: 10.0),
              child: Text(
                KaliumLocalization.of(context).changeCurrency,
                style: KaliumStyles.TextStyleDialogHeader,
              ),
            ),
            children: _buildCurrencyOptions(),
          );
        });
    SharedPrefsUtil.inst
        .setCurrency(AvailableCurrency(selection))
        .then((result) {
      if (StateContainer.of(context).curCurrency.currency != selection) {
        setState(() {
          StateContainer.of(context).curCurrency = AvailableCurrency(selection);
        });
        StateContainer.of(context).requestSubscribe();
      }
    });
  }

  Future<bool> _onBackButtonPressed() async {
    if (_contactsOpen) {
      setState(() {
        _contactsOpen = false;
      });
      _controller.reverse();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // Drawer in flutter doesn't have a built-in way to push/pop elements
    // on top of it like our Android counterpart. So we can override back button
    // presses and replace the main settings widget with contacts based on a bool
    return new WillPopScope(
        onWillPop: _onBackButtonPressed,
        child: Scaffold(
          key: _scaffoldKey,
          body: SlideTransition(
              position: _offsetFloat,
              child: Stack(
                overflow: Overflow.visible,
                children: <Widget> [
                  Positioned(
                    left: -1 * UIUtil.drawerWidth(context),
                    top: 0,
                    bottom: 0,
                    child: buildContacts(context),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: buildMainSettings(context),
                  ),
                ]
              )
            )
          ),
        );
  }

  Widget buildMainSettings(BuildContext context) {
    return Container(
      color: KaliumColors.backgroundDark,
      child: Column(
        children: <Widget>[
          Container(
            margin: EdgeInsets.only(left: 30.0, top: 60.0, bottom: 10.0),
            child: Row(
              children: <Widget>[
                Text(KaliumLocalization.of(context).settingsHeader, style: KaliumStyles.textStyleHeader(context),),
              ],
            ),
          ),
          Expanded(
              child: Stack(
            children: <Widget>[
              ListView(
                padding: EdgeInsets.only(top: 15.0),
                children: <Widget>[
                  Container(
                    margin: EdgeInsets.only(left: 30.0, bottom: 10),
                    child: Text(KaliumLocalization.of(context).preferences,
                        style: TextStyle(
                            fontSize: 16.0,
                            fontWeight: FontWeight.w100,
                            color: KaliumColors.text60)),
                  ),
                  Divider(height: 2),
                  KaliumSettings.buildSettingsListItemDoubleLine(
                      KaliumLocalization.of(context).changeCurrency,
                      StateContainer.of(context).curCurrency,
                      KaliumIcons.currency,
                      _currencyDialog),
                  Divider(height: 2),
                  buildSettingsListItemDoubleLine(
                      KaliumLocalization.of(context).language, KaliumLocalization.of(context).systemDefault, KaliumIcons.language),
                  _hasBiometrics ? Divider(height: 2) : null,
                  _hasBiometrics
                      ? KaliumSettings.buildSettingsListItemDoubleLine(
                          KaliumLocalization.of(context).authMethod,
                          _curAuthMethod,
                          KaliumIcons.fingerprint,
                          _authMethodDialog)
                      : null,
/*
                  Divider(height: 2),
                  buildSettingsListItemDoubleLine(
                      'Notifications', 'On', KaliumIcons.notifications),
*/
                  Divider(height: 2),
                  Container(
                    margin:
                        EdgeInsets.only(left: 30.0, top: 20.0, bottom: 10.0),
                    child: Text(KaliumLocalization.of(context).manage,
                        style: TextStyle(
                            fontSize: 16.0,
                            fontWeight: FontWeight.w100,
                            color: KaliumColors.text60)),
                  ),
                  Divider(height: 2),
                  buildSettingsListItemSingleLine(
                      KaliumLocalization.of(context).contactHeader, KaliumIcons.contacts, onPressed: () {
                    setState(() {
                      _contactsOpen = true;
                    });
                    _controller.forward();
                  }),
                  Divider(height: 2),
                  buildSettingsListItemSingleLine(
                      KaliumLocalization.of(context).backupSeed, KaliumIcons.backupseed, onPressed: () {
                    // Authenticate
                    SharedPrefsUtil.inst.getAuthMethod().then((authMethod) {
                      BiometricUtil.hasBiometrics().then((hasBiometrics) {
                        if (authMethod.method == AuthMethod.BIOMETRICS &&
                            hasBiometrics) {
                          BiometricUtil.authenticateWithBiometrics(
                                  KaliumLocalization.of(context).fingerprintSeedBackup)
                              .then((authenticated) {
                            if (authenticated) {
                              new KaliumSeedBackupSheet()
                                  .mainBottomSheet(context);
                            }
                          });
                        } else {
                          // PIN Authentication
                          Vault.inst.getPin().then((expectedPin) {
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (BuildContext context) {
                              return new PinScreen(
                                PinOverlayType.ENTER_PIN,
                                (pin) { 
                                  Navigator.of(context).pop();
                                  new KaliumSeedBackupSheet()
                                    .mainBottomSheet(context);
                                  },
                                expectedPin: expectedPin,
                                description: KaliumLocalization.of(context).pinSeedBackup,
                              );
                            }));
                          });
                        }
                      });
                    });
                  }),
/*
                  Divider(height: 2),
                  buildSettingsListItemSingleLine(
                      'Load from Paper Wallet', KaliumIcons.transferfunds,
                      onPressed: () {
                    Navigator.of(context).push(
                        MaterialPageRoute(builder: (BuildContext context) {
                      return new PinScreen(
                          PinOverlayType.NEW_PIN, pinEnteredTest);
                    }));
                  }),
*/
                  Divider(height: 2),
                  buildSettingsListItemSingleLine(
                      KaliumLocalization.of(context).changeRepAuthenticate, KaliumIcons.changerepresentative,
                      onPressed: () {
                    new KaliumChangeRepresentativeSheet()
                        .mainBottomSheet(context);
                  }),
                  Divider(height: 2),
                  buildSettingsListItemSingleLine(
                      KaliumLocalization.of(context).shareKalium, KaliumIcons.share,
                      onPressed: () {
                    Share.share(KaliumLocalization.of(context).shareKaliumText + "https://kalium.banano.cc");
                  }),
                  Divider(height: 2),
                  buildSettingsListItemSingleLine(KaliumLocalization.of(context).logout, KaliumIcons.logout,
                      onPressed: () {
                    KaliumDialogs.showConfirmDialog(
                        context,
                        KaliumLocalization.of(context).warning.toUpperCase(),
                        KaliumLocalization.of(context).logoutDetail,
                        KaliumLocalization.of(context).logoutAction, () {
                      // Show another confirm dialog
                      KaliumDialogs.showConfirmDialog(
                          context,
                          KaliumLocalization.of(context).logoutAreYouSure,
                          KaliumLocalization.of(context).logoutReassurance,
                          KaliumLocalization.of(context).yes.toUpperCase(), () {
                        Vault.inst.deleteAll().then((Null) {
                          SharedPrefsUtil.inst.deleteAll().then((result) {
                            StateContainer.of(context).logOut();
                            Navigator.of(context).pushNamedAndRemoveUntil(
                                '/', (Route<dynamic> route) => false);
                          });
                        });
                      });
                    });
                  }),
                  Divider(height: 2),
                  Padding(
                    padding: EdgeInsets.only(top: 10.0, bottom: 10.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text(StateContainer.of(context).appVersionString,
                            style: KaliumStyles.TextStyleVersion),
                      ],
                    ),
                  ),
                ].where(notNull).toList(),
              ),
              //List Top Gradient End
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  height: 20.0,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        KaliumColors.backgroundDark,
                        KaliumColors.backgroundDark00
                      ],
                      begin: Alignment(0.5, -1.0),
                      end: Alignment(0.5, 1.0),
                    ),
                  ),
                ),
              ), //List Top Gradient End
            ],
          )),
        ],
      ),
    );
  }

  Widget buildContacts(BuildContext context) {
    return Container(
      color: KaliumColors.backgroundDark,
      child: Column(
        children: <Widget>[
          // Back button and Contacts Text
          Container(
            margin: EdgeInsets.only(top: 60.0, bottom: 10.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    //Back button
                    Container(
                      height: 40,
                      width: 40,
                      margin: EdgeInsets.only(right: 10, left: 10),
                      child: FlatButton(
                          onPressed: () {
                            setState(() {
                              _contactsOpen = false;
                            });
                            _controller.reverse();
                          },
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(50.0)),
                          padding: EdgeInsets.all(8.0),
                          child: Icon(KaliumIcons.back,
                              color: KaliumColors.text, size: 24)),
                    ),
                    //Contacts Header Text
                    Text("Contacts", style: KaliumStyles.textStyleHeader(context),),
                  ],
                ),
                Row(
                  children: <Widget>[
                    //Import button
                    Container(
                      height: 40,
                      width: 40,
                      margin: EdgeInsets.only(right: 5),
                      child: FlatButton(
                          onPressed: () {
                            _importContacts();
                          },
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(50.0)),
                          padding: EdgeInsets.all(8.0),
                          child: Icon(KaliumIcons.import_icon,
                              color: KaliumColors.text, size: 24)),
                    ),
                    //Export button
                    Container(
                      height: 40,
                      width: 40,
                      margin: EdgeInsets.only(right: 20),
                      child: FlatButton(
                          onPressed: () {
                            _exportContacts();
                          },
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(50.0)),
                          padding: EdgeInsets.all(8.0),
                          child: Icon(KaliumIcons.export_icon,
                              color: KaliumColors.text, size: 24)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Contacts list + top and bottom gradients
          Expanded(
            child: Stack(
              children: <Widget>[
                // Contacts list
                ListView.builder(
                  padding: EdgeInsets.only(top: 15.0),
                  itemCount: _contacts.length,
                  itemBuilder: (context, index) {
                    return buildSingleContact(context, _contacts[index]);
                  },
                ),
                //List Top Gradient End
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: 20.0,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          KaliumColors.backgroundDark,
                          KaliumColors.backgroundDark00
                        ],
                        begin: Alignment(0.5, -1.0),
                        end: Alignment(0.5, 1.0),
                      ),
                    ),
                  ),
                ),
                //List Bottom Gradient End
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    height: 15.0,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          KaliumColors.backgroundDark00,
                          KaliumColors.backgroundDark,
                        ],
                        begin: Alignment(0.5, -1.0),
                        end: Alignment(0.5, 1.0),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            margin: EdgeInsets.only(top: 10),
            child: Row(
              children: <Widget>[
                KaliumButton.buildKaliumButton(KaliumButtonType.TEXT_OUTLINE,
                    KaliumLocalization.of(context).addContact, Dimens.BUTTON_BOTTOM_DIMENS, onPressed: () {
                  AddContactSheet().mainBottomSheet(context);
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSingleContact(
      BuildContext context, Contact contact) {
    return FlatButton(
      onPressed: () {
        ContactDetailsSheet(contact).mainBottomSheet(context);
      },
      padding: EdgeInsets.all(0.0),
      child: Column(
        children: <Widget>[
          Divider(height: 2),
          Container(
          padding: EdgeInsets.symmetric(vertical: 10.0),
          margin: new EdgeInsets.only(left: 30.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              //Container for monKey
              Container(
                margin: new EdgeInsets.only(right: 16.0),
                child: new Container(
                  height: 40,
                  width: 40,
                  child: contact.monkeyPath != null ? Image.file(File(contact.monkeyPath)) : SizedBox()
                ),
              ),
              //Contact info
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  //Contact name
                  Text(
                    contact.name,
                    style: KaliumStyles.TextStyleSettingItemHeader,
                  ),
                  //Contact address
                  Text(
                    Address(contact.address).getShortString(),
                    style: KaliumStyles.TextStyleTransactionAddress,
                  ),
                ],
              ),
            ],
          ),
        ),
        ]
      ),
    );
  }
}
