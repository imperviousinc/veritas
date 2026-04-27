use fabric::libveritas;
use fabric::libveritas::sip7;
use crate::VeritasError;

#[derive(uniffi::Record)]
pub struct Zone {
    pub anchor: u32,
    pub anchor_hash: Vec<u8>,
    pub badge: String,
    pub sovereignty: String,
    pub handle: String,
    pub canonical: String,
    pub alias: Option<String>,
    pub script_pubkey: Vec<u8>,
    pub num_id: Option<String>,
    pub records: Vec<u8>,
    pub fallback_records: Vec<u8>,
    pub delegate: DelegateState,
    pub commitment: CommitmentState,
}

#[derive(uniffi::Enum)]
pub enum DelegateState {
    Exists { script_pubkey: Vec<u8>, fallback_records: Vec<u8>, records: Vec<u8> },
    Empty,
    Unknown,
}

#[derive(uniffi::Enum)]
pub enum CommitmentState {
    Exists {
        state_root: Vec<u8>,
        prev_root: Option<Vec<u8>>,
        rolling_hash: Vec<u8>,
        block_height: u32,
        receipt_hash: Option<Vec<u8>>,
    },
    Empty,
    Unknown,
}


/// A parsed SIP-7 record (from unpacking). Includes `Malformed` for invalid rdata.
#[derive(uniffi::Enum)]
pub enum ParsedRecord {
    Seq { version: u64 },
    Txt { key: String, value: Vec<String> },
    Addr { key: String, value: Vec<String> },
    Blob { key: String, value: Vec<u8> },
    Sig { flags: u8, canonical: String, handle: String, sig: Vec<u8> },
    Malformed { rtype: u8, rdata: Vec<u8> },
    Unknown { rtype: u8, rdata: Vec<u8> },
}

impl<'a> From<sip7::ParsedRecord<'a>> for ParsedRecord {
    fn from(p: sip7::ParsedRecord<'a>) -> Self {
        match p {
            sip7::ParsedRecord::Seq(version) => ParsedRecord::Seq { version },
            sip7::ParsedRecord::Txt { key, value } => ParsedRecord::Txt {
                key: String::from(key),
                value: value.to_vec().into_iter().map(String::from).collect(),
            },
            sip7::ParsedRecord::Addr { key, value } => ParsedRecord::Addr {
                key: String::from(key),
                value: value.to_vec().into_iter().map(String::from).collect(),
            },
            sip7::ParsedRecord::Blob { key, value } => ParsedRecord::Blob {
                key: String::from(key),
                value: value.to_vec(),
            },
            sip7::ParsedRecord::Sig(sig) => ParsedRecord::Sig {
                flags: sig.flags,
                canonical: sig.canonical.to_owned().to_string(),
                handle: sig.handle.to_owned().to_string(),
                sig: sig.sig.to_vec(),
            },
            sip7::ParsedRecord::Malformed { rtype, rdata } => ParsedRecord::Malformed {
                rtype, rdata: rdata.to_vec(),
            },
            sip7::ParsedRecord::Unknown { rtype, rdata } => ParsedRecord::Unknown {
                rtype, rdata: rdata.to_vec(),
            },
        }
    }
}


/// SIP-7 record set - wire-format encoded records.
#[derive(uniffi::Object)]
pub struct RecordSet {
    inner: sip7::RecordSet,
}



#[uniffi::export]
impl RecordSet {
    /// Wrap raw wire bytes (lazy - no parsing until unpack).
    #[uniffi::constructor]
    pub fn new(data: Vec<u8>) -> Self {
        RecordSet { inner: sip7::RecordSet::new(data) }
    }

    /// Raw wire bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        self.inner.as_slice().to_vec()
    }

    /// Parse all records.
    pub fn unpack(&self) -> Result<Vec<ParsedRecord>, VeritasError> {
        self.inner.unpack()
            .map(|records| records.into_iter().map(Into::into).collect())
            .map_err(|e| VeritasError::InvalidInput { msg: e.to_string() })
    }

    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}

pub(crate) fn zone_from_inner(z: &libveritas::Zone, badge: String) -> Zone {
    Zone {
        anchor: z.anchor,
        anchor_hash: z.anchor_hash.to_vec(),
        badge,
        sovereignty: z.sovereignty.to_string(),
        handle: z.handle.to_string(),
        canonical: z.canonical.to_string(),
        alias: z.alias.as_ref().map(|a| a.to_string()),
        script_pubkey: z.script_pubkey.as_bytes().to_vec(),
        num_id: z.num_id.map(|n| n.to_string()),
        records: z.records.as_slice().to_vec(),
        fallback_records: z.fallback_records.as_slice().to_vec(),
        delegate: match &z.delegate {
            libveritas::ProvableOption::Exists { value } => DelegateState::Exists {
                script_pubkey: value.script_pubkey.as_bytes().to_vec(),
                fallback_records: value.fallback_records.as_slice().to_vec(),
                records: value.records.as_slice().to_vec(),
            },
            libveritas::ProvableOption::Empty => DelegateState::Empty,
            libveritas::ProvableOption::Unknown => DelegateState::Unknown,
        },
        commitment: match &z.commitment {
            libveritas::ProvableOption::Exists { value } => CommitmentState::Exists {
                state_root: value.onchain.state_root.to_vec(),
                prev_root: value.onchain.prev_root.map(|r| r.to_vec()),
                rolling_hash: value.onchain.rolling_hash.to_vec(),
                block_height: value.onchain.block_height,
                receipt_hash: value.receipt_hash.as_ref().map(|h| h.to_vec()),
            },
            libveritas::ProvableOption::Empty => CommitmentState::Empty,
            libveritas::ProvableOption::Unknown => CommitmentState::Unknown,
        },
    }
}

