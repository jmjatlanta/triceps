//
// (C) Copyright 2011-2013 Sergey A. Babkin.
// This file is a part of Triceps.
// See the file COPYRIGHT for the copyright notice and license information
//
//
// Various bits and pieces for the facet queues.

#include <app/QueFacet.h>

// XXX work in progress

namespace TRICEPS_NS {

// Adding a reader:
// * lock the nexus
// * make the new vector, with the next generation
// * lock the first old reader (if any) {
//   * bump the generation in the first reader
//   * put the initial next tray id into the new reader
//   * for each other old reader:
//     * lock, bump generation, unlock
//   * for each writer:
//     * lock writer, update the vector, unlock writer
// * } unlock the first old reader (if any)
// * put the new vector into the nexus
// * unlock the nexus
//
// Removing a reader:
// * lock the nexus
// * make the new vector, with the next generation
// * lock the first old reader {
//   * bump the generation in the first reader
//   * mark the removed reader as dead
//   * for each other old reader:
//     * lock, bump generation, set the next tray id from 1st, unlock
//   * for each writer:
//     * lock writer, update the vector, unlock writer
// * } unlock the first old reader (if any)
// * put the new vector into the nexus
// * unlock the nexus
//
// Writing:
// * pick the 1st reader in the vector
// * get the reader's lock {
//   * compare the generation in the reader and in the vector
//   * if different, release all the locks, pick the new vector, start from scratch
//   * take the next sequential id from the reader
//   * post the buffer at that id - sleep if the queue is full
// * } release the lock
// * for each other reader in the vector
//   * get the lock, deposit the buffer at that id, release it - sleep if the queue is full
//

ReaderQueue::ReaderQueue(QueEvent *qev, int qidx, Xtray::QueId limit):
	qev_(qev),
	qidx_(qidx),
	sizeLimit_(limit),
	rq_(0),
	prevId_(0),
	lastId_(0),
	gen_(-1),
	wrhole_(false),
	dead_(false),
	wrReady_(true)
{ }

bool ReaderQueue::writeFirst(int gen, Xtray *xt, Xtray::QueId &trayId)
{
	pw::lockmutex lm(mutex());
	if (dead_)
		return false;
	if (gen_ != gen)
		return false;

	// relative offset of the new xtray in the queue
	Xtray::QueId off = lastId_ - prevId_; // -1 and +1 cancel out

	while (off >= sizeLimit_) {
		condfull_.wait();
		if (dead_)
			return false;
		if (gen_ != gen)
			return false;
		off = lastId_ - prevId_; // queue would shift
	}

	insertQueL(xt, off);
	trayId = lastId_;
	return true;
}

void ReaderQueue::write(Xtray *xt, Xtray::QueId trayId)
{
	pw::lockmutex lm(mutex());
	if (dead_)
		return;
	Xtray::QueId off = trayId - prevId_ - 1;

	while (off >= sizeLimit_) {
		condfull_.wait();
		if (dead_)
			return;
		off = trayId - prevId_ - 1; // queue would shift
	}

	insertQueL(xt, off);
}

void ReaderQueue::insertQueL(Xtray *xt, Xtray::QueId off)
{
	Xdeque &q = writeq();
	if (q.size() == off) {
		// the nicely growing queue
		q.push_back(xt);
		lastId_++;
	} else {
		if (q.size() < off) {
			q.resize(off+1);
			lastId_ = prevId_ + off + 1;
			wrhole_ = true; // this created a hole in the middle
		}
		q[off] = xt;
	}

	if (off == 0) { // the front of the queue became readable
		wrReady_ = true; // before notification!
		qev_->ev_.signal();
	}
}

void ReaderQueue::setLastIdL(Xtray::QueId id)
{
	Xtray::QueId len = id - prevId_;
	Xdeque &q = writeq();
	if (q.size() < len) {
		q.resize(len);
		wrhole_ = true; // this created a hole in the queue
	}
	lastId_ = id;
}

bool ReaderQueue::refill()
{
	if (!readq().empty()) { // in this case should not be called to start with
		return true;
	}

	if (!wrReady_) { // reading the flag should be safe enough without a lock
		return false;
	}

	pw::lockmutex lm(mutex());

	if (wrhole_) {
		// have to copy one by one until find the hole or end of deque
		Xdeque rq = readq();
		Xdeque wq = writeq();
		while (!wq.empty()) {
			if (wq.front().isNull())
				break;
			rq.push_back(wq.front());
			wq.front() = NULL; // remove the reference to prevent it from getting stuck
			wq.pop_front();
			prevId_++;
		}
		if (wq.empty())
			wrhole_ = false; // the hole got filled, can use the fast way in the future
	} else {
		rq_ ^= 1; // just swap the queues in a fast way
		prevId_ = lastId_;
	}

	wrReady_ = false; // the write queue has nothing immediately readable now
	return !readq().empty();
}

void ReaderQueue::markDeadL()
{
	dead_ = true;
	writeq().clear();
	lastId_ = prevId_;
}

//-------------------------- NexusWriter --------------------------------

void NexusWriter::setReaderVec(ReaderVec *rv)
{
	pw::lockmutex lm(mutexNew_);
	readersNew_ = rv;
}

void NexusWriter::write(Xtray *xt)
{
	while (true) { // for an easy rerun
		if (readers_.isNull() || readers_->v().empty()) {
			// check if there is the new readers
			pw::lockmutex lm(mutexNew_);
			if (readers_ == readersNew_)
				return; // still nowhere to write to
			
			readers_ = readersNew_;
			continue;
		}

		ReaderVec::Vec::const_iterator end = readers_->v().end();
		ReaderVec::Vec::const_iterator it = readers_->v().begin();
		Xtray::QueId xid;
		if (!(*it)->writeFirst(readers_->gen(), xt, xid)) {
			// pick up the new readers and restart
			pw::lockmutex lm(mutexNew_);
			readers_ = readersNew_;
			continue;
		}
		for (++it; it != end; ++it) {
			(*it)->write(xt, xid);
		}

		break; // loop normally exits!
	}
}

}; // TRICEPS_NS
