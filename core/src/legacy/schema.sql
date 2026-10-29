CREATE TABLE messages (
        dmID INTEGER NOT NULL,
        is_verified BOOLEAN,
        _origin TEXT,
        dbIDSender TEXT,
        dmSender TEXT,
        dmSenderAddress TEXT,
        dmSenderType INTEGER,
        dmRecipient TEXT,
        dmRecipientAddress TEXT,
        dmAmbiguousRecipient TEXT,
        dmSenderOrgUnit TEXT,
        dmSenderOrgUnitNum TEXT,
        dbIDRecipient TEXT,
        dmRecipientOrgUnit TEXT,
        dmRecipientOrgUnitNum TEXT,
        dmToHands TEXT,
        dmAnnotation TEXT,
        dmRecipientRefNumber TEXT,
        dmSenderRefNumber TEXT,
        dmRecipientIdent TEXT,
        dmSenderIdent TEXT,
        dmLegalTitleLaw TEXT,
        dmLegalTitleYear TEXT,
        dmLegalTitleSect TEXT,
        dmLegalTitlePar TEXT,
        dmLegalTitlePoint TEXT,
        dmPersonalDelivery BOOLEAN,
        dmAllowSubstDelivery BOOLEAN,
        dmQTimestamp TEXT,
        dmDeliveryTime DATETIME,
        dmAcceptanceTime DATETIME,
        dmMessageStatus INTEGER,
        dmAttachmentSize INTEGER,
        _dmType TEXT,
        PRIMARY KEY (dmID),
        CHECK (is_verified IN (0, 1)),
        CHECK (dmPersonalDelivery IN (0, 1)),
        CHECK (dmAllowSubstDelivery IN (0, 1))
);
CREATE TABLE hashes (
        id INTEGER NOT NULL,
        message_id INTEGER,
        value TEXT,
        _algorithm TEXT,
        PRIMARY KEY (id),
        FOREIGN KEY(message_id) REFERENCES messages (dmID)
);
CREATE TABLE events (
        id INTEGER NOT NULL,
        message_id INTEGER,
        dmEventTime TEXT,
        dmEventDescr TEXT,
        PRIMARY KEY (id),
        FOREIGN KEY(message_id) REFERENCES messages (dmID)
);
CREATE TABLE process_state (
        message_id INTEGER NOT NULL,
        state INTEGER,
        PRIMARY KEY (message_id),
        FOREIGN KEY(message_id) REFERENCES messages (dmID)
);
CREATE TABLE raw_message_data (
        message_id INTEGER NOT NULL,
        message_type INTEGER,
        data TEXT,
        PRIMARY KEY (message_id),
        FOREIGN KEY(message_id) REFERENCES messages (dmID)
);
CREATE TABLE raw_delivery_info_data (
        message_id INTEGER NOT NULL,
        data TEXT,
        PRIMARY KEY (message_id),
        FOREIGN KEY(message_id) REFERENCES messages (dmID)
);
CREATE TABLE certificate_data (
        id INTEGER NOT NULL,
        der_data TEXT,
        PRIMARY KEY (id),
        UNIQUE (der_data)
);
CREATE TABLE message_certificate_data (
        message_id INTEGER,
        certificate_id INTEGER,
        FOREIGN KEY(message_id) REFERENCES messages (dmID),
        FOREIGN KEY(certificate_id) REFERENCES certificate_data (id)
);
CREATE TABLE files (
        id INTEGER NOT NULL,
        message_id INTEGER,
        attNum INTEGER,
        _dmFileDescr TEXT,
        _dmUpFileGuid TEXT,
        _dmFileGuid TEXT,
        _dmMimeType TEXT,
        _dmFormat TEXT,
        _dmFileMetaType TEXT,
        _dmFileSize INTEGER,
        dmEncodedContent TEXT,
        CONSTRAINT pk_id PRIMARY KEY (id),
        CONSTRAINT fk_message_id FOREIGN KEY(message_id) REFERENCES messages (dmID) ON DELETE CASCADE
);
CREATE TABLE supplementary_message_data (
        message_id INTEGER NOT NULL,
        message_type INTEGER,
        dmVODZ BOOLEAN,
        attsNum INTEGER,
        specMessFlag INTEGER,
        read_locally BOOLEAN,
        download_date DATETIME,
        custom_data TEXT,
        CONSTRAINT pk_message_id PRIMARY KEY (message_id),
        CONSTRAINT fk_message_id FOREIGN KEY(message_id) REFERENCES messages (dmID) ON DELETE CASCADE,
        CONSTRAINT ck_read_locally CHECK (read_locally IN (0, 1))
);
