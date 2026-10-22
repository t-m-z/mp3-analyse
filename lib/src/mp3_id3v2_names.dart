part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Frame names, version membership and genre table.
// ---------------------------------------------------------------------------

const _mp3FrameNamesV22 = <String, String>{
  'BUF': 'Recommended buffer size',
  'CNT': 'Play counter',
  'COM': 'Comments',
  'CRA': 'Audio encryption',
  'CRM': 'Encrypted meta frame',
  'ETC': 'Event timing codes',
  'EQU': 'Equalization',
  'GEO': 'General encapsulated object',
  'IPL': 'Involved people list',
  'LNK': 'Linked information',
  'MCI': 'Music CD identifier',
  'MLL': 'MPEG location lookup table',
  'PIC': 'Attached picture',
  'POP': 'Popularimeter',
  'REV': 'Reverb',
  'RVA': 'Relative volume adjustment',
  'SLT': 'Synchronized lyric/text',
  'STC': 'Synced tempo codes',
  'TAL': 'Album/Movie/Show title',
  'TBP': 'BPM (beats per minute)',
  'TCM': 'Composer',
  'TCO': 'Content type (genre)',
  'TCR': 'Copyright message',
  'TDA': 'Date',
  'TDY': 'Playlist delay',
  'TEN': 'Encoded by',
  'TFT': 'File type',
  'TIM': 'Time',
  'TKE': 'Initial key',
  'TLA': 'Language(s)',
  'TLE': 'Length',
  'TMT': 'Media type',
  'TOA': 'Original artist(s)/performer(s)',
  'TOF': 'Original filename',
  'TOL': 'Original lyricist(s)/text writer(s)',
  'TOR': 'Original release year',
  'TOT': 'Original album/Movie/Show title',
  'TP1': 'Lead artist(s)/Lead performer(s)/Soloist(s)/Performing group',
  'TP2': 'Band/Orchestra/Accompaniment',
  'TP3': 'Conductor/Performer refinement',
  'TP4': 'Interpreted, remixed, or otherwise modified by',
  'TPA': 'Part of a set',
  'TPB': 'Publisher',
  'TRC': 'ISRC (international standard recording code)',
  'TRD': 'Recording dates',
  'TRK': 'Track number/Position in set',
  'TSI': 'Size',
  'TSS': 'Software/hardware and settings used for encoding',
  'TT1': 'Content group description',
  'TT2': 'Title/Songname/Content description',
  'TT3': 'Subtitle/Description refinement',
  'TXT': 'Lyricist/text writer',
  'TXX': 'User defined text information frame',
  'TYE': 'Year',
  'UFI': 'Unique file identifier',
  'ULT': 'Unsychronized lyric/text transcription',
  'WAF': 'Official audio file webpage',
  'WAR': 'Official artist/performer webpage',
  'WAS': 'Official audio source webpage',
  'WCM': 'Commercial information',
  'WCP': 'Copyright/Legal information',
  'WPB': 'Publishers official webpage',
  'WXX': 'User defined URL link frame',
};

/// Non-standard frames written by iTunes and others into ID3v2.2 tags.
const _mp3FrameNamesV22Extensions = <String, String>{
  'TCP': 'iTunes compilation flag',
  'TS2': 'Album artist sort order (iTunes)',
  'TSA': 'Album sort order (iTunes)',
  'TSC': 'Composer sort order (iTunes)',
  'TSP': 'Performer sort order (iTunes)',
  'TST': 'Title sort order (iTunes)',
};

/// ID3v2.2 identifiers mapped to their ID3v2.3 counterpart (same content layout).
const _mp3V22ToV23 = <String, String>{
  'BUF': 'RBUF', 'CNT': 'PCNT', 'COM': 'COMM', 'CRA': 'AENC', 'CRM': 'CRM', //
  'ETC': 'ETCO', 'EQU': 'EQUA', 'GEO': 'GEOB', 'IPL': 'IPLS', 'LNK': 'LINK',
  'MCI': 'MCDI', 'MLL': 'MLLT', 'PIC': 'APIC', 'POP': 'POPM', 'REV': 'RVRB',
  'RVA': 'RVAD', 'SLT': 'SYLT', 'STC': 'SYTC', 'TAL': 'TALB', 'TBP': 'TBPM',
  'TCM': 'TCOM', 'TCO': 'TCON', 'TCR': 'TCOP', 'TDA': 'TDAT', 'TDY': 'TDLY',
  'TEN': 'TENC', 'TFT': 'TFLT', 'TIM': 'TIME', 'TKE': 'TKEY', 'TLA': 'TLAN',
  'TLE': 'TLEN', 'TMT': 'TMED', 'TOA': 'TOPE', 'TOF': 'TOFN', 'TOL': 'TOLY',
  'TOR': 'TORY', 'TOT': 'TOAL', 'TP1': 'TPE1', 'TP2': 'TPE2', 'TP3': 'TPE3',
  'TP4': 'TPE4', 'TPA': 'TPOS', 'TPB': 'TPUB', 'TRC': 'TSRC', 'TRD': 'TRDA',
  'TRK': 'TRCK', 'TSI': 'TSIZ', 'TSS': 'TSSE', 'TT1': 'TIT1', 'TT2': 'TIT2',
  'TT3': 'TIT3', 'TXT': 'TEXT', 'TXX': 'TXXX', 'TYE': 'TYER', 'UFI': 'UFID',
  'ULT': 'USLT', 'WAF': 'WOAF', 'WAR': 'WOAR', 'WAS': 'WOAS', 'WCM': 'WCOM',
  'WCP': 'WCOP', 'WPB': 'WPUB', 'WXX': 'WXXX', 'TCP': 'TCMP', 'TS2': 'TSO2',
  'TSA': 'TSOA', 'TSC': 'TSOC', 'TSP': 'TSOP', 'TST': 'TSOT',
};

/// ID3v2.3 and ID3v2.4 frames (see [_mp3OnlyV23] / [_mp3OnlyV24]).
const _mp3FrameNames = <String, String>{
  'AENC': 'Audio encryption',
  'APIC': 'Attached picture',
  'ASPI': 'Audio seek point index',
  'CHAP': 'Chapter (ID3v2 chapter frame addendum)',
  'COMM': 'Comments',
  'COMR': 'Commercial frame',
  'CTOC': 'Table of contents (ID3v2 chapter frame addendum)',
  'ENCR': 'Encryption method registration',
  'EQU2': 'Equalisation (2)',
  'EQUA': 'Equalization',
  'ETCO': 'Event timing codes',
  'GEOB': 'General encapsulated object',
  'GRID': 'Group identification registration',
  'IPLS': 'Involved people list',
  'LINK': 'Linked information',
  'MCDI': 'Music CD identifier',
  'MLLT': 'MPEG location lookup table',
  'OWNE': 'Ownership frame',
  'PCNT': 'Play counter',
  'POPM': 'Popularimeter',
  'POSS': 'Position synchronisation frame',
  'PRIV': 'Private frame',
  'RBUF': 'Recommended buffer size',
  'RVA2': 'Relative volume adjustment (2)',
  'RVAD': 'Relative volume adjustment',
  'RVRB': 'Reverb',
  'SEEK': 'Seek frame',
  'SIGN': 'Signature frame',
  'SYLT': 'Synchronised lyric/text',
  'SYTC': 'Synchronised tempo codes',
  'TALB': 'Album/Movie/Show title',
  'TBPM': 'BPM (beats per minute)',
  'TCOM': 'Composer',
  'TCON': 'Content type (genre)',
  'TCOP': 'Copyright message',
  'TDAT': 'Date',
  'TDEN': 'Encoding time',
  'TDLY': 'Playlist delay',
  'TDOR': 'Original release time',
  'TDRC': 'Recording time',
  'TDRL': 'Release time',
  'TDTG': 'Tagging time',
  'TENC': 'Encoded by',
  'TEXT': 'Lyricist/Text writer',
  'TFLT': 'File type',
  'TIME': 'Time',
  'TIPL': 'Involved people list',
  'TIT1': 'Content group description',
  'TIT2': 'Title/songname/content description',
  'TIT3': 'Subtitle/Description refinement',
  'TKEY': 'Initial key',
  'TLAN': 'Language(s)',
  'TLEN': 'Length',
  'TMCL': 'Musician credits list',
  'TMED': 'Media type',
  'TMOO': 'Mood',
  'TOAL': 'Original album/movie/show title',
  'TOFN': 'Original filename',
  'TOLY': 'Original lyricist(s)/text writer(s)',
  'TOPE': 'Original artist(s)/performer(s)',
  'TORY': 'Original release year',
  'TOWN': 'File owner/licensee',
  'TPE1': 'Lead performer(s)/Soloist(s)',
  'TPE2': 'Band/orchestra/accompaniment',
  'TPE3': 'Conductor/performer refinement',
  'TPE4': 'Interpreted, remixed, or otherwise modified by',
  'TPOS': 'Part of a set',
  'TPRO': 'Produced notice',
  'TPUB': 'Publisher',
  'TRCK': 'Track number/Position in set',
  'TRDA': 'Recording dates',
  'TRSN': 'Internet radio station name',
  'TRSO': 'Internet radio station owner',
  'TSIZ': 'Size',
  'TSOA': 'Album sort order',
  'TSOP': 'Performer sort order',
  'TSOT': 'Title sort order',
  'TSRC': 'ISRC (international standard recording code)',
  'TSSE': 'Software/Hardware and settings used for encoding',
  'TSST': 'Set subtitle',
  'TXXX': 'User defined text information frame',
  'TYER': 'Year',
  'UFID': 'Unique file identifier',
  'USER': 'Terms of use',
  'USLT': 'Unsynchronised lyric/text transcription',
  'WCOM': 'Commercial information',
  'WCOP': 'Copyright/Legal information',
  'WOAF': 'Official audio file webpage',
  'WOAR': 'Official artist/performer webpage',
  'WOAS': 'Official audio source webpage',
  'WORS': 'Official Internet radio station homepage',
  'WPAY': 'Payment',
  'WPUB': 'Publishers official webpage',
  'WXXX': 'User defined URL link frame',
};

/// Well known non-standard frames (iTunes, podcasts).
const _mp3FrameNamesExtensions = <String, String>{
  'GRP1': 'Grouping (iTunes)',
  'MVIN': 'Movement number (iTunes)',
  'MVNM': 'Movement name (iTunes)',
  'PCST': 'Podcast flag (iTunes)',
  'TCAT': 'Podcast category (iTunes)',
  'TCMP': 'Compilation flag (iTunes)',
  'TDES': 'Podcast description (iTunes)',
  'TGID': 'Podcast identifier (iTunes)',
  'TKWD': 'Podcast keywords (iTunes)',
  'TSO2': 'Album artist sort order (iTunes)',
  'TSOC': 'Composer sort order (iTunes)',
  'WFED': 'Podcast feed URL (iTunes)',
  'XRVA': 'Relative volume adjustment (experimental, like RVA2)',
  'XSOA': 'Album sort order (experimental)',
  'XSOP': 'Performer sort order (experimental)',
  'XSOT': 'Title sort order (experimental)',
};

const _mp3OnlyV23 = <String>{'EQUA', 'IPLS', 'RVAD', 'TDAT', 'TIME', 'TORY', 'TRDA', 'TSIZ', 'TYER'};

const _mp3OnlyV24 = <String>{
  'ASPI', 'EQU2', 'RVA2', 'SEEK', 'SIGN', 'TDEN', 'TDOR', 'TDRC', 'TDRL', //
  'TDTG', 'TIPL', 'TMCL', 'TMOO', 'TPRO', 'TSOA', 'TSOP', 'TSOT', 'TSST',
};

String _mp3FrameName(String id, int major) {
  if (major == 2) return _mp3FrameNamesV22[id] ?? _mp3FrameNamesV22Extensions[id] ?? 'unknown frame';
  return _mp3FrameNames[id] ?? _mp3FrameNamesExtensions[id] ?? 'unknown frame';
}

/// Null if [id] is a standard frame of ID3v2.[major], otherwise a remark.
String? _mp3FrameStandardInfo(String id, int major) {
  if (major == 2) {
    if (_mp3FrameNamesV22.containsKey(id)) return null;
    if (_mp3FrameNamesV22Extensions.containsKey(id)) return 'non-standard frame (${_mp3FrameNamesV22Extensions[id]})';
    return 'frame ID is not defined in ID3v2.2';
  }
  if (_mp3FrameNames.containsKey(id)) {
    if (major == 3 && _mp3OnlyV24.contains(id)) return 'frame is only defined in ID3v2.4, not in ID3v2.3';
    if (major == 4 && _mp3OnlyV23.contains(id)) return 'frame is defined in ID3v2.3 but was removed in ID3v2.4';
    return null;
  }
  if (_mp3FrameNamesExtensions.containsKey(id)) return 'non-standard frame (${_mp3FrameNamesExtensions[id]})';
  if (id.startsWith('X') || id.startsWith('Y') || id.startsWith('Z')) {
    return 'experimental frame (IDs starting with X, Y or Z are free for experiments)';
  }
  return 'frame ID is not defined in ID3v2.$major';
}

/// ID3v1 genres 0-79 plus the Winamp extensions 80-191.
const _mp3Genres = <String>[
  'Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge', 'Hip-Hop', // 0-7
  'Jazz', 'Metal', 'New Age', 'Oldies', 'Other', 'Pop', 'R&B', 'Rap', // 8-15
  'Reggae', 'Rock', 'Techno', 'Industrial', 'Alternative', 'Ska', 'Death Metal', 'Pranks', // 16-23
  'Soundtrack', 'Euro-Techno', 'Ambient', 'Trip-Hop', 'Vocal', 'Jazz+Funk', 'Fusion', 'Trance', // 24-31
  'Classical', 'Instrumental', 'Acid', 'House', 'Game', 'Sound Clip', 'Gospel', 'Noise', // 32-39
  'Alternative Rock', 'Bass', 'Soul', 'Punk', 'Space', 'Meditative', 'Instrumental Pop', 'Instrumental Rock', // 40-47
  'Ethnic', 'Gothic', 'Darkwave', 'Techno-Industrial', 'Electronic', 'Pop-Folk', 'Eurodance', 'Dream', // 48-55
  'Southern Rock', 'Comedy', 'Cult', 'Gangsta', 'Top 40', 'Christian Rap', 'Pop/Funk', 'Jungle', // 56-63
  'Native American', 'Cabaret', 'New Wave', 'Psychedelic', 'Rave', 'Showtunes', 'Trailer', 'Lo-Fi', // 64-71
  'Tribal', 'Acid Punk', 'Acid Jazz', 'Polka', 'Retro', 'Musical', 'Rock & Roll', 'Hard Rock', // 72-79
  'Folk', 'Folk-Rock', 'National Folk', 'Swing', 'Fast Fusion', 'Bebop', 'Latin', 'Revival', // 80-87
  'Celtic', 'Bluegrass', 'Avantgarde', 'Gothic Rock', 'Progressive Rock', 'Psychedelic Rock', 'Symphonic Rock', 'Slow Rock', // 88-95
  'Big Band', 'Chorus', 'Easy Listening', 'Acoustic', 'Humour', 'Speech', 'Chanson', 'Opera', // 96-103
  'Chamber Music', 'Sonata', 'Symphony', 'Booty Bass', 'Primus', 'Porn Groove', 'Satire', 'Slow Jam', // 104-111
  'Club', 'Tango', 'Samba', 'Folklore', 'Ballad', 'Power Ballad', 'Rhythmic Soul', 'Freestyle', // 112-119
  'Duet', 'Punk Rock', 'Drum Solo', 'A Cappella', 'Euro-House', 'Dance Hall', 'Goa', 'Drum & Bass', // 120-127
  'Club-House', 'Hardcore Techno', 'Terror', 'Indie', 'BritPop', 'Afro-Punk', 'Polsk Punk', 'Beat', // 128-135
  'Christian Gangsta Rap', 'Heavy Metal', 'Black Metal', 'Crossover', 'Contemporary Christian', 'Christian Rock', 'Merengue', 'Salsa', // 136-143
  'Thrash Metal', 'Anime', 'JPop', 'Synthpop', 'Christmas', 'Art Rock', 'Baroque', 'Bhangra', // 144-151
  'Big Beat', 'Breakbeat', 'Chillout', 'Downtempo', 'Dub', 'EBM', 'Eclectic', 'Electro', // 152-159
  'Electroclash', 'Emo', 'Experimental', 'Garage', 'Global', 'IDM', 'Illbient', 'Industro-Goth', // 160-167
  'Jam Band', 'Krautrock', 'Leftfield', 'Lounge', 'Math Rock', 'New Romantic', 'Nu-Breakz', 'Post-Punk', // 168-175
  'Post-Rock', 'Psytrance', 'Shoegaze', 'Space Rock', 'Trop Rock', 'World Music', 'Neoclassical', 'Audiobook', // 176-183
  'Audio Theatre', 'Neue Deutsche Welle', 'Podcast', 'Indie Rock', 'G-Funk', 'Dubstep', 'Garage Rock', 'Psybient', // 184-191
];

String _mp3GenreName(int index) {
  if (index >= 0 && index < _mp3Genres.length) return _mp3Genres[index];
  if (index == 255) return 'none (255)';
  return 'unknown genre ($index)';
}

/// Resolves "(13)", "(13)(RX)Refinement", "13", "Rock" ... into genre names.
List<String> _mp3ResolveGenres(List<String> values) {
  final out = <String>[];
  final reference = RegExp(r'^\((\d+|RX|CR)\)');
  for (final v in values) {
    var s = v.trim();
    var m = reference.firstMatch(s);
    while (m != null) {
      final g = m.group(1)!;
      out.add(g == 'RX' ? 'Remix' : (g == 'CR' ? 'Cover' : _mp3GenreName(int.parse(g))));
      s = s.substring(m.end);
      m = reference.firstMatch(s);
    }
    if (s.startsWith('((')) s = s.substring(1);
    if (s.isEmpty) continue;
    final n = int.tryParse(s);
    if (n != null) {
      out.add(_mp3GenreName(n));
    } else if (s == 'RX') {
      out.add('Remix');
    } else if (s == 'CR') {
      out.add('Cover');
    } else {
      out.add(s);
    }
  }
  return out;
}
