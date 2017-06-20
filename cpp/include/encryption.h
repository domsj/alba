/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#pragma once

#include <iostream>

namespace alba {
namespace encryption {

enum class encryption_t { NO_ENCRYPTION, ENCRYPTED };

class EncryptInfo {
public:
  virtual encryption_t get_encryption() const = 0;
  virtual void print(std::ostream &os) const = 0;

  virtual bool supports_partial_decrypt() const = 0;

  virtual ~EncryptInfo(){};
};

class NoEncryption : public EncryptInfo {
  virtual encryption_t get_encryption() const {
    return encryption_t::NO_ENCRYPTION;
  }

  virtual void print(std::ostream &os) const { os << "NoEncryption()"; }

  virtual bool supports_partial_decrypt() const { return true; }
};

enum class algo_t { AES };
enum class chaining_mode_t { CBC, CTR };
enum class key_length_t { L256 };

class Encrypted : public EncryptInfo {
  /* | Encrypted of Encryption.algo * key_identification */

  /* type algo = */
  /*   | AES of chaining_mode * key_length */
  /* type chaining_mode = */
  /*   | CBC */
  /*   | CTR */
  /* type key_length = */
  /*   | L256 */

  /* type key_identification = */
  /*   | KeySha256 of string */

public:
  virtual encryption_t get_encryption() const {
    return encryption_t::ENCRYPTED;
  }

  virtual void print(std::ostream &os) const { os << "Encrypted()"; }

  virtual bool supports_partial_decrypt() const {
    return mode == chaining_mode_t::CTR;
  }

  virtual bool partial_decrypt(unsigned char *buf, int len,
                               std::string &enc_key, std::string &ctr,
                               int offset) const;

  algo_t algo;
  chaining_mode_t mode;
  key_length_t key_length;

  std::string key_identification;
};

std::ostream &operator<<(std::ostream &, const encryption_t &);
std::ostream &operator<<(std::ostream &, const EncryptInfo &);
std::ostream &operator<<(std::ostream &, const algo_t &);
std::ostream &operator<<(std::ostream &, const chaining_mode_t &);
}
}
