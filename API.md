### Changes from Kyoto-based Seqant annotator (Seqant 3.0)
1. No alt_names key. This field was used solely for displaying features from gene tracks. The API standardizes on the following naming convention: track_name.feature. The Tracks package owns this knowledge.


2. Every single track handles it's own href generation function, always called the same thing, such that the consuming class never has to introspect to know what method to call. At the moment this may be getData($dataFromDbManager). Previously this was as_href.

