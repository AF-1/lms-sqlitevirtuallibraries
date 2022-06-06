SQLite Virtual Libraries
====

A plugin for [Logitech Media Server](https://github.com/Logitech/slimserver)<br>

**Create your own virtual libraries** using files with an *SQLite statement* and **create browse menus**[^1] for *any* LMS virtual library, incl. those not created with SQLVL.
<br>

💡 **For more information on how to use this plugin, see the [wiki](https://github.com/AF-1/lms-sqlitevirtuallibraries/wiki) page.**
<br><br>

## Requirements

- LMS version >= 7.**9**
- LMS database = **SQLite**
<br><br><br>

## Installation

You should be able to install **SQLite Virtual Libraries** from the LMS main repository (LMS plugin library):<br>**LMS > Settings > Plugins**.<br>

If you want to test a new patch that hasn't made it into a release version yet or you need to install a previous version you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).

*Previously released* versions are available here for a very *limited* time after the release of a new version. The official LMS plugins page is updated about twice a day so it usually takes a couple of hours before new released versions are listed.
<br><br>

## Translation
The [**strings.txt**](https://github.com/AF-1/lms-sqlitevirtuallibraries/blob/main/SQLiteVirtualLibraries/strings.txt) file contains all localizable strings. Once you're done **testing** the plugin with your translated strings just create a pull request on GitHub.<br>
* Please try not to use the [**single**](https://www.fileformat.info/info/unicode/char/27/index.htm) quote character (apostrophe) or the [**double**](https://www.fileformat.info/info/unicode/char/0022/index.htm) quote character (quotation mark) in your translated strings. They could cause problems. You can use the [*right single quotation mark*](https://www.fileformat.info/info/unicode/char/2019/index.htm) or the [*double quotation mark*](https://www.fileformat.info/info/unicode/char/201d/index.htm) instead. And if possible, avoid (special) characters that are used as [**metacharacters**](https://en.wikipedia.org/wiki/Metacharacter) in programming languages (Perl), regex or SQLite.
* It's probably not a bad idea to keep the translated strings roughly as long as the original ones.<br>
* Some of these strings are supposed to be used with different UIs: my tests usually cover the LMS *default* skin, *Material* skin, *piCorePlayer* (or any other jivelite player like *SqueezePlay*) and maybe some ip3k player like *Boom* if applicable.
* Please leave *(multiple) blank lines* (used to visually delineate different parts) as they are.
<br><br>

[^1]: Browse menus are provided by LMS. Under certain circumstances you may see (empty) albums or artists in some menus that shouldn't be there. There's nothing I can do about it because LMS creates and provides these menus.<br>Just go down one level: click to *show all tracks* or *show all albums*.<br>In case this LMS issue ever gets resolved, I'll update this page.
